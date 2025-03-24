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
        
        profit_gen_DA = Dict(g => (MCP - gen_cost[g]) * value(P[g]) for g in generators)
        println("\n🔸 Generator Profits:")
        for g in generators
            println("$g: ", round(profit_gen_DA[g], digits=2))
        end


        profit_wind_DA = Dict(w => MCP * value(W[w]) for w in wind_farms)
        println("\n🔸 Wind Farm Profits:")
        for w in wind_farms
            println("$w: ", round(profit_wind_DA[w], digits=2))
        end


        W_DA = Dict(w => value(W[w]) for w in wind_farms)

        return MCP, P_DA, W_DA, profit_gen_DA, profit_wind_DA
    else
        error("❌ Optimization failed!")
    end
end


# -----------------------------
# Balancing Market Model
# -----------------------------

function BM_model(gen_cap::Dict, wind_cap::Dict, gen_cost::Dict, P_D::Dict, demand_bid::Dict, Ci_up::Dict, Ci_down::Dict, curtail_cost::Float64, P_DA::Dict, W_DA::Dict, scheme::String, MCP::Float64, profit_gen_DA::Dict, profit_wind_DA::Dict)
    model_BM = Model(GLPK.Optimizer)
        
    # Define sets
    generators = collect(keys(gen_cap))   # All generators
    wind_farms = collect(keys(wind_cap))
    demands = collect(keys(P_D))

    # Balancing Market Generators (Subset of all generators)
    balancing_generators = ["G1", "G2", "G3", "G4", "G5", "G6", "G7", "G9", "G10", "G11", "G12"]

    # Now define Ci_up and Ci_down for all balancing generators
    Ci_up = Dict(g => MCP + gen_cost[g] * 0.1 for g in balancing_generators)
    Ci_down = Dict(g => MCP - gen_cost[g] * 0.15 for g in balancing_generators)
    curtail_cost = 500.0

    # DA Results
    gen_DA = copy(P_DA)
    wind_DA = copy(W_DA)

    # Apply Imbalances
    wind_BM = Dict(w => W_DA[w] * (w in ["W1", "W2", "W3"] ? 0.90 : 1.15) for w in wind_farms)
    gen_BM = Dict(g => (g == "G8" ? 0.0 : gen_DA[g]) for g in generators)    

    diff_wind = sum(wind_DA[w] for w in wind_farms) - sum(wind_BM[w] for w in wind_farms)
    diff_G8 = gen_DA["G8"]
    imbalance_overall = diff_wind + diff_G8

    total_wind = sum(wind_BM[w] for w in wind_farms)
    total_gen_DA = sum(gen_DA[g] for g in generators)

    # Variables
    @variable(model_BM, P_up[g in balancing_generators] >= 0) 
    @variable(model_BM, P_down[g in balancing_generators] >= 0) 
    @variable(model_BM, C_curtail >= 0)

    # Constraints    
    for g in balancing_generators                          
        @constraint(model_BM, P_up[g] <= gen_cap[g] - gen_DA[g])
        @constraint(model_BM, P_down[g] <= gen_DA[g])
    end

    balancing_system = @constraint(model_BM,
        sum(P_up[g] - P_down[g] for g in balancing_generators) + C_curtail == imbalance_overall
    )

    # Objective: Minimize total cost
    @objective(model_BM, Min,
        sum(Ci_up[g] * P_up[g] for g in balancing_generators) -
        sum(Ci_down[g] * P_down[g] for g in balancing_generators) +
        C_curtail * curtail_cost
    )
    
    optimize!(model_BM)

    if termination_status(model_BM) == MOI.OPTIMAL
        println("✅ Balancing Market Solved")
        println("🔹 Objective Value: ", objective_value(model_BM))
    
        println("\n🔸 Upward (Generators):")
        for g in balancing_generators
            println("$g: ", value(P_up[g]))
        end

        println("\n🔸 Downward (Generators):")
        for g in balancing_generators
            println("$g: ", value(P_down[g]))
        end

        # Extract balancing price BA_MCP
        BA_MCP = round(JuMP.dual(balancing_system), digits=2)
        println("🔹 Balancing Market Clearing Price (BA_MCP): ", BA_MCP)

        # --- COMMENT -----
        # The following code calculates the profit and revenue for each generator and wind farm
        # based on the BA_MCP and MCP values. The code is not optimized and can be improved.
        # Currently, it is following the specific Power Deficit shemce where G8 experiences outage.
        # An improved version would consider all possible scenarios, using overall system imbalance.
        # ----------------

        # For the balancing generators
        total_profit_bg = 0.0
        total_revenue_bg = 0.0

        for g in balancing_generators
            profit_bg = (BA_MCP * value(P_up[g])) - (gen_cost[g] * value(P_up[g]))
            revenue_bg = MCP * gen_DA[g] + profit_bg

            total_profit_bg += profit_bg
            total_revenue_bg += revenue_bg

            println("$g Profit: ", round(profit_bg, digits=2), ", $g Revenue: ", round(revenue_bg, digits=2))
        end

        # Wind Farms - shceme pricing
        total_profit_one_price = 0.0
        total_profit_two_price = 0.0
        total_revenue_one_price = 0.0
        total_revenue_two_price = 0.0

        for w in wind_farms
            imbalance_wind = value(wind_BM[w]) - value(W_DA[w])

            println("\n 💨 $w imbalance: ", round(value(imbalance_wind), digits=2))
            
            # Producing more than expected
            if imbalance_wind > 0
                profit_one_price = BA_MCP * imbalance_wind
                profit_two_price = MCP * imbalance_wind
            else
                profit_one_price = BA_MCP * imbalance_wind
                profit_two_price = BA_MCP * imbalance_wind
            end
                revenues_one_price = MCP * W_DA[w] + profit_one_price
                revenues_two_price = MCP * W_DA[w] + profit_two_price

                total_profit_one_price += profit_one_price
                total_profit_two_price += profit_two_price
                total_revenue_one_price += revenues_one_price
                total_revenue_two_price += revenues_two_price

                println("$w: One-price Profit = $(round(profit_one_price, digits=2)), Two-price Profit = $(round(profit_two_price, digits=2))")
                println("$w: One-price Revenue = $(round(revenues_one_price, digits=2)), Two-price Revenue = $(round(revenues_two_price, digits=2))")
        end

        # G8 - regulation pricing
        g8_profit = BA_MCP * (-diff_G8)
        g8_revenue = MCP * gen_DA["G8"] + g8_profit

        println("\n🔸 G8 Profit: $(round(g8_profit, digits=2)), Revenue: $(round(g8_revenue, digits=2))")

    else
        error("❌ Balancing Market Optimization Failed!")
    end
end



# -----------------------------
# Run Models
# -----------------------------

# Run Day-Ahead Market
println("\n🔍 Day-Ahead Market:")
MCP, P_DA, W_DA, profit_gen_DA, profit_wind_DA = DA_model(gen_cap, wind_cap, gen_cost, P_D, demand_bid)

# Run Balancing Market
println("\n🔍 Balancing Market:")
BM_model(
    gen_cap, wind_cap, gen_cost, P_D, demand_bid,
    Ci_up, Ci_down, curtail_cost,
    P_DA, W_DA, "two-price", MCP, profit_gen_DA, profit_wind_DA
)
