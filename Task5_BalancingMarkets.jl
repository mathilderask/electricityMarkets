using Pkg
#Pkg.add("CSV")
#Pkg.add("DataFrames")
#Pkg.add("JuMP")
#Pkg.add("GLPK")
#Pkg.add("PyPlot")


using CSV, DataFrames, JuMP, GLPK

# Read CSV files and specify column types to ensure Float64 conversion
df_GUD = CSV.read("GeneratingUnitsData.csv", DataFrame; delim=';', types=Dict(:Pi_max => Float64, :Ci => Float64))
df_LP = CSV.read("LoadProfile.csv", DataFrame; delim=';', types=Dict(Symbol("System_demand_(MW)") => Float64))
df_LN = CSV.read("LoadNodes.csv", DataFrame;  delim=';', types=Dict(:Percentage_SystemLoad => Float64))
df_WP = CSV.read("WindFarmData.csv", DataFrame;  delim=';', types=Dict(:Pi_max => Float64))

# Extract data directly as Float64
Pi_max = df_GUD[!, :"Pi_max"]  # Maximum power output
Ci = df_GUD[!, :"Ci"]          # Production cost
Di = df_LP[!, "System_demand_(MW)"]  # Load profile
LN = df_LN[!, :"Percentage_SystemLoad"]  # Load node percentages
Dp = df_LN[!, :"U_d"]  # Demand price bids
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
#-------------------------------------------------------------
function run_market_model(Pi_max, WF_Prod, Ci, Di_first, LN, Dp)

    D_FirstHour = [Di_first * LN[i] for i in eachindex(LN)]

    m = Model(GLPK.Optimizer)
    h = 1:length(WF_Prod)
    i = 1:length(Pi_max)
    j = 1:length(D_FirstHour)

    @variable(m, W[h])
    @variable(m, P[i])
    @variable(m, D[j])

    @constraint(m, [k in h], 0 <= W[k] <= WF_Prod[k])
    @constraint(m, [k in i], 0 <= P[k] <= Pi_max[k])
    @constraint(m, [k in j], 0 <= D[k] <= D_FirstHour[k])
    power_balance = @constraint(m,( sum(D[k] for k in j) - sum(P[k] for k in i) - sum(W[k] for k in h))*(-1) == 0)

    @objective(m, Max, sum(D[k] * Dp[k] for k in j) - sum(P[k] * Ci[k] for k in i))

    optimize!(m)

    if termination_status(m) == MOI.OPTIMAL
        MCP = round(JuMP.dual(power_balance), digits=2)
        profits_wind = [(MCP) * JuMP.value(W[i]) for i in h]
        profits_gen = [(MCP - Ci[i]) * JuMP.value(P[i]) for i in i]
        welfare = JuMP.objective_value(m)
        return profits_wind, profits_gen, welfare
    else
        println("Optimization failed: ", termination_status(m))
        return [], [], 0.0
    end
end

# ----------------------------------------------
# Run market model without imbalances
profits_wind_noimb, profits_gen_noimb, welfare_noimb = run_market_model(
    Pi_max_original, WF_Prod_original, Ci, Di_first, LN, Dp)

# Run market model with imbalances (after applying them above)
profits_wind_imb, profits_gen_imb, welfare_imb = run_market_model(
    df_GUD[!, :Pi_max], WF_Prod, Ci, Di_first, LN, Dp)
#----------------------------------------------


#---------------------- PLOT 1 ----------------------
using PyPlot

# Combine profits (sum of wind and generators)
total_profits_noimb = sum(profits_wind_noimb) + sum(profits_gen_noimb)
total_profits_imb = sum(profits_wind_imb) + sum(profits_gen_imb)

# Bar plot
labels = ["Without Imbalances", "With Imbalances"]
profits = [total_profits_noimb, total_profits_imb]

figure(figsize=(6, 5))
bar(labels, profits, color=["green", "red"])
ylabel("Total Market Profits (\$)")
title("Total Profits With and Without Imbalances")
grid(true, axis="y")
gcf()  # Show figure
# savefig("profits_comparison.svg")


# Per generator and per wind farm profits (example with just generators)
figure(figsize=(10, 5))
bar(1:length(profits_gen_noimb), profits_gen_noimb, width=0.4, label="No Imbalances", align="center", color="green")
bar((1:length(profits_gen_imb)) .+ 0.4, profits_gen_imb, width=0.4, label="With Imbalances", align="center", color="blue")
xlabel("Generators")
ylabel("Profits (\$)")
title("Generator Profits With and Without Imbalances")
legend()
grid(true, axis="y")
gcf()

# --------------- PLOT 2 ----------------------------

using PyPlot

# Number of wind farms
n_windfarms = length(WF_Prod)

# Bar width
bar_width = 0.35

# X-axis positions
x = 1:n_windfarms

# Plot bar plot
figure(figsize=(8, 5))
bar(x .- bar_width/2, profits_wind_noimb, width=bar_width, label="Without Imbalances", color="green")
bar(x .+ bar_width/2, profits_wind_imb, width=bar_width, label="With Imbalances", color="blue")

# Labels and title
xlabel("Wind Farm Number")
ylabel("Profit (\$)")
title("Wind Farm Profits With and Without Imbalances")
xticks(x)  # Set x-axis labels to wind farm numbers
legend()
grid(true, axis="y")
gcf()  # Show figure
# savefig("windfarm_profits_comparison.svg")  # Optional: Save figure


# --------------- PLOT 3 ----------------------------
