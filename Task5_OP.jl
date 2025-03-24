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
Pi_max = df_GUD[!, :Pi_max]
Ci = df_GUD[!, :Ci]
Di = df_LP[!, "System_demand_(MW)"]
LN = df_LN[!, :Percentage_SystemLoad]
Dp = df_DBH[1, :]
WF_Prod = df_WP[!, :Pi_max]

# Store original values
Pi_max_original = copy(Pi_max)
WF_Prod_original = copy(WF_Prod)

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
model_DA = Model(GLPK.Optimizer)

@variable(model_DA, 0 <= P_gen[g in generators] <= gen_cap[g])
@variable(model_DA, 0 <= P_wind[w in wind_farms] <= wind_cap[w])
@variable(model_DA, 0 <= P_dem[d in demands] <= P_D[d])

@objective(model_DA, Max,
    sum(demand_bid[d] * P_dem[d] for d in demands) -
    sum(gen_cost[g] * P_gen[g] for g in generators)
)

power_balance = @constraint(model_DA,
    sum(P_dem[d] for d in demands) ==
    sum(P_gen[g] for g in generators) +
    sum(P_wind[w] for w in wind_farms)
)

optimize!(model_DA)

if termination_status(model_DA) == MOI.OPTIMAL
    λ_DA = dual(power_balance)
    println("✅ Day-Ahead Clearing Price: \$$(round(λ_DA, digits=2))")
else
    error("Day-ahead optimization failed.")
end

P_gen_DA = Dict(g => value(P_gen[g]) for g in generators)
P_wind_DA = Dict(w => value(P_wind[w]) for w in wind_farms)

# -----------------------------
# Apply Imbalances
# -----------------------------
gen_actual = copy(gen_cap)
wind_actual = copy(wind_cap)

gen_actual["G8"] = 0.0  # Outage
wind_actual["W1"] *= 0.9
wind_actual["W2"] *= 0.9
wind_actual["W4"] *= 1.15
wind_actual["W5"] *= 1.15

# -----------------------------
# Balancing Market
# -----------------------------
curt_cost = 500.0
balancing_generators = ["G1", "G2", "G3", "G4", "G5", "G6"]
Ci_up = Dict(g => gen_cost[g] * 1.1 for g in balancing_generators)
Ci_down = Dict(g => gen_cost[g] * 0.87 for g in balancing_generators)
