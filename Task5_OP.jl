using CSV, DataFrames, JuMP, GLPK

# -----------------------------
# Load Data
# -----------------------------
df_GUD = CSV.read("GeneratingUnitsData.csv", DataFrame; delim=';', types=Dict(:Pi_max => Float64, :Ci => Float64))
df_LP = CSV.read("LoadProfile.csv", DataFrame; delim=';', types=Dict(Symbol("System_demand_(MW)") => Float64))
df_LN = CSV.read("LoadNodes.csv", DataFrame; delim=';', types=Dict(:Percentage_SystemLoad => Float64))
df_WP = CSV.read("WindFarmData.csv", DataFrame; delim=';', types=Dict(:Pi_max => Float64))
df_DBH = CSV.read("DemandBidHour.csv", DataFrame; delim=';', header=1)

# -----------------------------
# Extract Data
# -----------------------------
Pi_max = df_GUD[!, :Pi_max]             # Max production
Ci = df_GUD[!, :Ci]                     # Production cost
Di = df_LP[!, "System_demand_(MW)"]     # Load profile / Demand
LN = df_LN[!, :Percentage_SystemLoad]   # Load node percentages
Dp = df_DBH[1, :]                       # Demand price bids
WF_Prod = df_WP[!, :Pi_max]             # Wind farm production

# Store original values
Pi_max_original = copy(Pi_max)
WF_Prod_original = copy(WF_Prod)

# Set names
generators = ["G$i" for i in 1:12]
wind_farms = ["W$i" for i in 1:6]
demands = ["D$i" for i in 1:17]

# Create Dicts
gen_cost = Dict(generators[i] => Ci[i] for i in 1:12)
gen_cap = Dict(generators[i] => Pi_max[i] for i in 1:12)
wind_cap = Dict(wind_farms[i] => WF_Prod[i] for i in 1:6)
wind_cost = Dict(wind_farms[i] => 0.0 for i in 1:6)
demand_bid = Dict(demands[i] => Dp[i] for i in 1:17)
demand_fraction = Dict(demands[i] => LN[i] for i in 1:17)

# Total demand for first hour
D_total = Di[1]
P_D = Dict(d => demand_fraction[d] * D_total for d in demands)

# -----------------------------
# Day-Ahead Market Clearing
# -----------------------------

function DA_model(gen_cap::Dict, wind_cap::Dict, gen_cost::Dict, P_D::Dict, demand_bid::Dict)
    model_DA = Model(GLPK.Optimizer)

    generators = collect(keys(gen_cap))
    wind_farms = collect(keys(wind_cap))
    demands = collect(keys(P_D))

    @variable(model_DA, W[w in wind_farms])
    @variable(model_DA, P[g in generators])
    @variable(model_DA, D[d in demands])

    # Constraints
    @constraint(model_DA, [w in wind_farms], 0 <= W[w] <= wind_cap[w])
    @constraint(model_DA, [g in generators], 0 <= P[g] <= gen_cap[g])
    @constraint(model_DA, [d in demands], 0 <= D[d] <= P_D[d])

    # Power Balance
    power_balance = @constraint(model_DA, sum(D[d] for d in demands) == sum(P[g] for g in generators) + sum(W[w] for w in wind_farms))

    # Objective: Maximize social welfare
    @objective(model_DA, Max, sum(D[d] * demand_bid[d] for d in demands) - sum(P[g] * gen_cost[g] for g in generators))

    optimize!(model_DA)

    if termination_status(model_DA) == MOI.OPTIMAL
        MCP = (-1)*round(JuMP.dual(power_balance), digits=2)
        println("✅ Market Clearing Price (MCP): ", MCP)
        println("🔹 Objective Value (Social Welfare): ", objective_value(model_DA))

        # Create Dict for dispatch
        P_DA = Dict(g => value(P[g]) for g in generators)

        println("\n🔸 Dispatch (Generators):")
        for g in generators
            println("$g: ", value(P[g]))
        end

        println("\n🔸 Dispatch (Wind Farms):")
        for w in wind_farms
            println("$w: ", value(W[w]))
        end

        println("\n🔸 Demand Served:")
        for d in demands
            println("$d: ", value(D[d]))
        end

        println("\n🔸 Generator Profits:")
        for g in generators
            profit = (MCP - gen_cost[g]) * value(P[g])
            println("$g: ", round(profit, digits=2))
        end

        println("\n🔸 Wind Farm Profits:")
        for w in wind_farms
            profit = MCP * value(W[w])
            println("$w: ", round(profit, digits=2))
        end

        println("\n🔸 Demand Utilities:")
        for d in demands
            utility = value(D[d]) * (demand_bid[d] - MCP)
            println("$d: ", round(utility, digits=2))
        end
        return MCP, P_DA
    else
        error("❌ Optimization failed!")
    end
end


# -----------------------------
# Balancing Market Model
# -----------------------------

function BM_model(gen_cap::Dict, wind_cap::Dict, gen_cost::Dict, P_D::Dict, demand_bid::Dict, Ci_up::Dict, Ci_down::Dict, curtail_cost::Float64, P_DA::Dict, scheme::String, MCP::Float64)
    model_BM = Model(GLPK.Optimizer)
        
    # Define sets
    generators = collect(keys(gen_cap))   # All generators
    wind_farms = collect(keys(wind_cap))
    demands = collect(keys(P_D))

    # Store original values
    gen_actual = copy(gen_cap)
    wind_actual = copy(wind_cap)

    # Apply Imbalances
    gen_cap = Dict(g => (g == "G8" ? 0.0 : gen_cap[g]) for g in generators)
    wind_cap = Dict(w => wind_cap[w] * (w in ["W1", "W2", "W3"] ? 0.9 : 1.15) for w in wind_farms)
    
    # Balancing Market Generators (Subset of all generators)
    balancing_generators = ["G1", "G2", "G3", "G4", "G5", "G6"]
    Ci_up = Dict(g => gen_cost[g] * 1.1 for g in balancing_generators)
    Ci_down = Dict(g => gen_cost[g] * 0.85 for g in balancing_generators)

    # Variables
    @variable(model_BM, W[w in wind_farms] >= 0)
    @variable(model_BM, P[g in generators] >= 0)  # All generators
    @variable(model_BM, D[d in demands] >= 0)
    @variable(model_BM, P_up[g in balancing_generators] >= 0)  # Only balancing generators
    @variable(model_BM, P_down[g in balancing_generators] >= 0) 
    @variable(model_BM, C_curtail >= 0)

    # Debugging Information (Check Correct Keys)
    #println("✅ Generators: ", generators)
    #println("✅ Balancing Generators: ", balancing_generators)
    #println("✅ P Keys: ", keys(P))
    #println("✅ P_up Keys: ", keys(P_up))
    #println("✅ P_down Keys: ", keys(P_down))

    # Constraints
    @constraint(model_BM, [w in wind_farms], W[w] <= wind_cap[w])
    @constraint(model_BM, [d in demands], D[d] <= P_D[d])
    
    # Only enforce generation limits for generators **in the model**
    @constraint(model_BM, [g in generators], P[g] <= gen_cap[g]) 

    # **Only balancing generators can adjust** (Prevent indexing errors)
    for g in balancing_generators
        @constraint(model_BM, P[g] + P_up[g] - P_down[g] <= gen_cap[g])  # Ensuring feasible limits
    end

    # Power Balance
    power_balance = @constraint(model_BM,
        sum(D[d] for d in demands) ==
        sum(P[g] for g in generators) +   
        sum(P_up[g] - P_down[g] for g in balancing_generators) +  
        sum(W[w] for w in wind_farms) + C_curtail
    )

    # Objective: Minimize total cost
    @objective(model_BM, Min,
        sum(gen_cost[g] * P[g] for g in generators) +
        sum(Ci_up[g] * P_up[g] for g in balancing_generators) -
        sum(Ci_down[g] * P_down[g] for g in balancing_generators) +
        C_curtail * curtail_cost
    )

    optimize!(model_BM)

    if termination_status(model_BM) == MOI.OPTIMAL
        println("✅ Balancing Market Solved")
        println("🔹 Objective Value: ", objective_value(model_BM))
        
        println("\n🔸 Dispatch (Generators):")
        for g in generators
            println("$g: ", value(P[g]))
        end

        println("\n🔸 Dispatch (Wind Farms):")
        for w in wind_farms
            println("$w: ", value(W[w]))
        end
        println("\n🔸 Imbalance Settlements ($scheme scheme):")
        for g in generators
            DA = P_DA[g]       # Day-ahead dispatch
            BM = value(P[g])   # Real-time dispatch
            imbalance = BM - DA

            UP = value(P_up[g])
            DOWN = value(P_down[g])
            net_dispatch = BM + UP - DOWN

            if isapprox(imbalance, 0.0; atol=1e-3)
                println("$g: No imbalance")
                continue
            end

            settlement = 0.0
            cost = gen_cost[g]

            if scheme == "one-price"
                if imbalance > 0  # Excess: Supplied more than committed
                    price = MCP - 0.15 * cost
                else  # Deficit: Supplied less than committed
                    price = MCP + 0.10 * cost
                end
                settlement = imbalance * price

            elseif scheme == "two-price"
                # Day-ahead scheduled quantity: DA
                # Real-time dispatch: BM

                DA_price = MCP
                BM_price = round(JuMP.dual(power_balance), digits=2)

                # Compute up/down regulation
                scheduled = DA
                dispatched = BM + (g in balancing_generators ? value(P_up[g]) - value(P_down[g]) : 0.0)
                imbalance = dispatched - scheduled

                # Total revenue: scheduled at DA price, deviation at balancing price
                revenue = scheduled * DA_price + imbalance * BM_price
                profit = revenue - cost * dispatched # Profit = Revenue - Cost

                if imbalance < 0  # Generator underproduced (deficit)
                    if system_imbalance < 0  # System short → worsening
                        price = MCP
                    else  # System has excess → helping
                        price = MCP + 0.10 * cost
                    end
                else  # Generator overproduced (excess)
                    if system_imbalance > 0  # System long → worsening
                        price = MCP
                    else  # System is short → helping
                        price = MCP - 0.15 * cost
                    end
                end
                settlement = imbalance * price
                println("System imbalance (net MW): ", round(system_imbalance, digits=2), ", Profit: ", round(profit, digits=2))
            end

        println("$g: Imbalance = $(round(imbalance, digits=2)), Settlement = $(round(settlement, digits=2)), Revenue: $(round(settlement + cost * DA, digits=2))")

    end

    else
        error("❌ Balancing Market Optimization Failed!")
    end
end



# -----------------------------
# Run Models
# -----------------------------

# Run Day-Ahead Market
println("\n🔍 Day-Ahead Market:")
#P_DA, MCP = DA_model(gen_cap, wind_cap, gen_cost, P_D, demand_bid)

# Run Balancing Market
println("\n🔍 Balancing Market:")
BM_model(gen_cap, wind_cap, gen_cost, P_D, demand_bid, Ci_up, Ci_down, curtail_cost, MCP, "one-price", P_DA)
