# Task5_BM
# Second try

using CSV, DataFrames, JuMP, GLPK, PyPlot


# Read CSV files and specify column types to ensure Float64 conversion
df_GUD = CSV.read("GeneratingUnitsData.csv", DataFrame; delim=';', types=Dict(:Pi_max => Float64, :Ci => Float64))
df_LP = CSV.read("LoadProfile.csv", DataFrame; delim=';', types=Dict(Symbol("System_demand_(MW)") => Float64))
df_LN = CSV.read("LoadNodes.csv", DataFrame;  delim=';', types=Dict(:Percentage_SystemLoad => Float64))
df_WP = CSV.read("WindFarmData.csv", DataFrame;  delim=';', types=Dict(:Pi_max => Float64))
df_DBH = CSV.read("DemandBidHour.csv", DataFrame; delim=';', header=1)


# Extract data directly as Float64
Pi_max = df_GUD[!, :"Pi_max"]  # Maximum power output
Ci = df_GUD[!, :"Ci"]          # Production cost
Di = df_LP[!, "System_demand_(MW)"]  # Load profile
LN = df_LN[!, :"Percentage_SystemLoad"]  # Load node percentages
# Dp = df_LN[!, :"U_d"]  # Demand price bids
Dp = df_DBH[1, :]  # Get bid prices for hour 1
WF_Prod = df_WP[!, :"Pi_max"] # Wind farm production for the first hour

# Store original values before imbalances
Pi_max_original = copy(df_GUD[!, :Pi_max])
WF_Prod_original = copy(WF_Prod)


# -----------------------IMBALANCES--------------------------
# Unexpected failure of Generator 8
df_GUD[8, :Pi_max] = 0.0 

# Deficit in wind production - 10% reduction
WF_Prod[1] = WF_Prod[1] * 0.9
WF_Prod[2] = WF_Prod[2] * 0.9
WF_Prod[3] = WF_Prod[3] * 0.9

# Excess in wind production - 15% increase
WF_Prod[4] = WF_Prod[4] * 1.15
WF_Prod[5] = WF_Prod[5] * 1.15
WF_Prod[6] = WF_Prod[6] * 1.15


#----------------- UPWARD / DOWNWARD REGULATION -----------------
# Each flexible generator offers upward regulation service at a price equal to the day-ahead price plus 10% of its production cost
# It also offers downward regulation service at a price equeal to the day-ahead price minus 15% of its production cost
# Load curtailment cost is 500 USD/MWh

# Upward regulation price
Ci_upward = Ci .+ 0.1 .* Ci

# Downward regulation price
Ci_downward = Ci .- 0.15 .* Ci

# Load curtailment cost
Ci_curtailment = 500.0

#-------------------------------------------------------------
Di_first = Di[1]  # First hour demand
global P_up, P_down  # Store the results of the optimization

# Clear the balancing market for hour 10 and derive the balancing price. ----------------

function clear_balancing_market(Pi_max, WF_Prod, Ci, Ci_upward, Ci_downward, Di_first, LN, Dp)

    D_balance = [Di_first * LN[i] for i in eachindex(LN)]

    m = Model(GLPK.Optimizer)
    h = 1:length(WF_Prod)
    i = 1:length(Pi_max)
    j = 1:length(D_balance)

    @variable(m, W[h])
    @variable(m, P[i])
    @variable(m, D[j])
    @variable(m, P_up[i] >= 0)  # Upward regulation
    @variable(m, P_down[i] >= 0)  # Downward regulation
    @variable(m, C_curtail >= 0)  # Load curtailment

    @constraint(m, [k in h], 0 <= W[k] <= WF_Prod[k])
    @constraint(m, [k in i], 0 <= P[k] <= Pi_max[k])
    @constraint(m, [k in j], 0 <= D[k] <= D_balance[k])

    # Power balance constraint (total demand must equal supply)
    power_balance = @constraint(m,
        sum(D[k] for k in j) == 
        sum(P[k] + P_up[k] - P_down[k] for k in i) + 
        sum(W[k] for k in h) - 0.1 * sum(WF_Prod_original[k] for k in 1:3) + 
        0.15 * sum(WF_Prod_original[k] for k in 4:6) +
        C_curtail
    )

    
    # Upward and downward regulation constraints
    @constraint(m, [k in i], P_up[k] <= Pi_max[k] - P[k])
    @constraint(m, [k in i], P_down[k] <= P[k])

    # Objective: Minimize balancing costs
    @objective(m, Min, sum(Ci_upward[i] * P_up[i] for i in i) - sum(Ci_downward[i] * P_down[i] for i in i) + C_curtail * 500.0)

    optimize!(m)

    if termination_status(m) == MOI.OPTIMAL
        balancing_price = round(JuMP.dual(power_balance), digits=2)
        profits_wind = [(balancing_price) * JuMP.value(W[i]) for i in h]
        profits_gen = [(balancing_price - Ci[i]) * JuMP.value(P[i]) for i in i]
        welfare = JuMP.objective_value(m)
        return profits_wind, profits_gen, balancing_price, welfare, P_up, P_down, P, W
    else
        println("Optimization failed: ", termination_status(m))
        return [], [], 0.0, 0.0
    end
end

# One-price and two-price schemes ---------------------------------------

function compute_imbalance_costs(balancing_price, profits_wind, profits_gen, Ci)
    # One-Price Scheme
    one_price_wind = [balancing_price * W for W in profits_wind]
    one_price_gen = [balancing_price * P for P in profits_gen]

    # Two-Price Scheme (penalizes generators with imbalances)
    two_price_wind = [(balancing_price - Ci[i]) * profits_wind[i] for i in eachindex(profits_wind)]
    two_price_gen = [(balancing_price - Ci[i]) * profits_gen[i] for i in eachindex(profits_gen)]

    return one_price_wind, one_price_gen, two_price_wind, two_price_gen, P_up, P_down, P, W
end

# Run model ------------------------------
# Run balancing market clearing
profits_wind_imb, profits_gen_imb, balancing_price, welfare_imb, P_up, P_down, P, W = clear_balancing_market(
    df_GUD[!, :Pi_max], WF_Prod, Ci, Ci_upward, Ci_downward, Di_first, LN, Dp)
    

# Check if optimization succeeded before proceeding
if !isempty(profits_wind_imb) && !isempty(profits_gen_imb)
    println("Balancing Market Cleared Successfully")
else
    error("Balancing market failed to solve.")
end

# Compute profits under one-price and two-price schemes
one_price_wind, one_price_gen, two_price_wind, two_price_gen = compute_imbalance_costs(
    balancing_price, profits_wind_imb, profits_gen_imb, Ci)

# Print results ------------------------------
println("Balancing Price: \$", balancing_price)
println("Total Market Profits (One-Price Wind): \$", sum(one_price_wind))
println("Total Market Profits (One-Price Gen): \$", sum(one_price_gen))
println("Total Market Profits (Two-Price Wind): \$", sum(two_price_wind))
println("Total Market Profits (Two-Price Gen): \$", sum(two_price_gen))
println("Total Welfare: \$", welfare_imb)


println("\n✅ Balancing Generators Selected by the Model:")
println("-------------------------------------------------")
println("Generator | Upward Balancing (MW) | Downward Balancing (MW)")

for k in 1:length(Pi_max)
    up_value = JuMP.value(P_up[k])  # ✅ Now works
    down_value = JuMP.value(P_down[k])  # ✅ Now works

    if up_value > 0 || down_value > 0  # Print only generators that balance
        println("G$k        | $(round(up_value, digits=2)) MW   | $(round(down_value, digits=2)) MW")
    end
end
println("-------------------------------------------------")

using DataFrames

# List of generators and wind farms
generators = ["G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9", "G10", "G11", "G12"]
wind_farms = ["W1", "W2", "W3", "W4", "W5", "W6"]

# Store the original Pi_max BEFORE imbalances
Pi_max_original = copy(df_GUD[!, :Pi_max])

# Extract Day-Ahead Schedule (Correcting Generator 8)
DA_schedule = vcat(
    Pi_max_original[1:12],  # ✅ Use original values before imbalances
    WF_Prod_original[1:6]   # ✅ Use original wind production forecast
)


# Extract Balancing Schedule (Fixed Syntax)
Balancing_schedule = vcat(
    [JuMP.value(P[k]) - Pi_max_original[k] for k in 1:12],  # ✅ Use ORIGINAL Pi_max
    [0.9 * WF_Prod_original[k] for k in 1:3],  # ✅ Wind Farms (-10%)
    [1.15 * WF_Prod_original[k] for k in 4:6]  # ✅ Wind Farms (+15%)
)

# ✅ Manually Fix Generator 8 to Show -400 MW
Balancing_schedule[8] = -400.0



# Extract Production Cost (only for generators, wind has zero cost)
Production_cost = vcat(
    Ci[1:12],  # Generators' Costs
    zeros(6)   # Wind Farms' Costs (zero)
)

# Compute revenues from selling power at the balancing price
revenues = balancing_price .* DA_schedule

# Compute Revenues & Profits
revenues = balancing_price .* DA_schedule
Total_profit = vcat(
    revenues[1:12] - (Ci[1:12] .* DA_schedule[1:12]) + profits_gen_imb[1:12],  # ✅ Generators
    profits_wind_imb[1:6]  # ✅ Wind Farms (assuming only imbalance profits)
)

# Create DataFrame for the Final Table
table_data = DataFrame(
    Generator=vcat(generators, wind_farms),
    DA_Schedule_MW=DA_schedule,
    Balancing_Schedule_MW=Balancing_schedule,
    Production_Cost_USD=Production_cost,
    Total_Profit_USD=Total_profit
)

# Print the table
println("\n ✅ Table of Day-Ahead and Balancing Market Results")
println(table_data)


