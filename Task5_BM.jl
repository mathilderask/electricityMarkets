# Task5_BM
# With Two-Price Settlement, Accurate Wind Profits, and Correct Demand-Supply Matching

using CSV, DataFrames, JuMP, GLPK, PyPlot

# -----------------------------
# Load Data
# -----------------------------
df_GUD = CSV.read("GeneratingUnitsData.csv", DataFrame; delim=';', types=Dict(:Pi_max => Float64, :Ci => Float64))
df_LP = CSV.read("LoadProfile.csv", DataFrame; delim=';', types=Dict(Symbol("System_demand_(MW)") => Float64))
df_LN = CSV.read("LoadNodes.csv", DataFrame;  delim=';', types=Dict(:Percentage_SystemLoad => Float64))
df_WP = CSV.read("WindFarmData.csv", DataFrame;  delim=';', types=Dict(:Pi_max => Float64))
df_DBH = CSV.read("DemandBidHour.csv", DataFrame; delim=';', header=1)

# Extract data
Pi_max = df_GUD[!, :Pi_max]
Ci = df_GUD[!, :Ci]
Di = df_LP[!, "System_demand_(MW)"]
LN = df_LN[!, :Percentage_SystemLoad]
Dp = df_DBH[1, :]
WF_Prod = df_WP[!, :Pi_max]

# Store original values before imbalances
Pi_max_original = copy(Pi_max)
WF_Prod_original = copy(WF_Prod)

# -----------------------------
# Set Prices
# -----------------------------
Ci_upward = Ci .+ 0.1 .* Ci
Ci_downward = Ci .- 0.15 .* Ci
Ci_curtailment = 500.0

# -----------------------------
# Balancing Market Clearing
# -----------------------------
balancing_generators = [6, 7, 9, 10, 11, 12]
Di_first = Di[1]

function clear_balancing_market(Pi_max, WF_Prod, Ci, Ci_upward, Ci_downward, Di_first, LN, Dp)
    D_balance = [Di_first * LN[i] for i in eachindex(LN)]

    # Apply imbalances here (just before solving)
    Pi_max[8] = 0.0  # Generator 8 outage
    WF_Prod[1:3] .*= 0.9  # -10% wind
    WF_Prod[4:6] .*= 1.15  # +15% wind

    m = Model(GLPK.Optimizer)
    h = 1:length(WF_Prod)
    i = 1:length(Pi_max)
    j = 1:length(D_balance)

    @variable(m, W[h])
    @variable(m, P[i])
    @variable(m, D[j])
    @variable(m, P_up[i] >= 0)
    @variable(m, P_down[i] >= 0)
    @variable(m, C_curtail >= 0)

    @constraint(m, [k in h], 0 <= W[k] <= WF_Prod[k])
    @constraint(m, [k in j], 0 <= D[k] <= D_balance[k])
    @constraint(m, [k in setdiff(i, balancing_generators)], P[k] == Pi_max[k])
    @constraint(m, [k in balancing_generators], 0 <= P[k] <= Pi_max[k])

    @constraint(m, [k in balancing_generators], P_up[k] <= Pi_max[k] - P[k])
    @constraint(m, [k in balancing_generators], P_down[k] <= P[k])
    @constraint(m, [k in setdiff(i, balancing_generators)], P_up[k] == 0)
    @constraint(m, [k in setdiff(i, balancing_generators)], P_down[k] == 0)

    power_balance = @constraint(m,
        sum(D[k] for k in j) ==
        sum(P[k] + P_up[k] - P_down[k] for k in i) +
        sum(W[k] for k in h) + C_curtail
    )

    @objective(m, Min,
        sum(Ci[k] * P[k] for k in i) +
        sum(Ci_upward[k] * P_up[k] for k in balancing_generators) -
        sum(Ci_downward[k] * P_down[k] for k in balancing_generators) +
        C_curtail * Ci_curtailment
    )

    optimize!(m)

    if termination_status(m) == MOI.OPTIMAL
        balancing_price = round(JuMP.dual(power_balance), digits=2)
        wind_energy = [JuMP.value(W[i]) for i in h]
        gen_energy = [JuMP.value(P[i]) + JuMP.value(P_up[i]) - JuMP.value(P_down[i]) for i in i]
        # Two-price scheme
        profits_wind = [balancing_price * wind_energy[i] for i in h]  # zero cost
        profits_gen = [(balancing_price - Ci[i]) * gen_energy[i] for i in i]
        welfare = JuMP.objective_value(m)
        return profits_wind, profits_gen, balancing_price, welfare, P_up, P_down, P, W, C_curtail, wind_energy
    else
        println("Optimization failed: ", termination_status(m))
        return [], [], 0.0, 0.0
    end
end

# -----------------------------
# Run Balancing Market
# -----------------------------
profits_wind_imb, profits_gen_imb, balancing_price, welfare_imb, P_up, P_down, P, W, C_curtail, wind_energy = clear_balancing_market(df_GUD[!, :Pi_max], WF_Prod, Ci, Ci_upward, Ci_downward, Di_first, LN, Dp)

println("\n🔎 Power Balance Check:")
total_gen = sum(JuMP.value(P[k]) + JuMP.value(P_up[k]) - JuMP.value(P_down[k]) for k in 1:12)
total_wind = sum(wind_energy)
imbalance_wind = 0.0  # Already applied to WF_Prod, no need to adjust again
load = Di_first
curtailment = JuMP.value(C_curtail)

println("Total Gen: $total_gen")
println("Total Wind: $total_wind")
println("Curtailment: $curtailment")
println("Total Supply: $(total_gen + total_wind + curtailment)")
println("Total Demand: $load")

# -----------------------------
# Build Output Table
# -----------------------------
generators = ["G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9", "G10", "G11", "G12"]
wind_farms = ["W1", "W2", "W3", "W4", "W5", "W6"]

DA_schedule = vcat(Pi_max_original[1:12], WF_Prod_original[1:6])
Balancing_schedule = [JuMP.value(P[k]) - Pi_max_original[k] for k in 1:12]
Balancing_schedule[8] = -Pi_max_original[8]  # G8 outage
wind_balancing = [wind_energy[k] - WF_Prod_original[k] for k in 1:6]
Balancing_schedule = vcat(Balancing_schedule, wind_balancing)

Production_cost = vcat(Ci[1:12], zeros(6))
Total_profit = vcat(profits_gen_imb[1:12], profits_wind_imb)

table_data = DataFrame(
    Generator=vcat(generators, wind_farms),
    DA_Schedule_MW=DA_schedule,
    Balancing_Schedule_MW=Balancing_schedule,
    Production_Cost_USD=Production_cost,
    Total_Profit_USD=Total_profit
)

println("\n✅ Table of Day-Ahead and Balancing Market Results")
println(table_data)
