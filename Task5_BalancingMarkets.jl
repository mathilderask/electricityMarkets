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

df_GUD[8, :Pi_max] = 0.0

# Compute the load for each node in only the first hour
Di_first = Di[1]
D_FirstHour = [Di_first * LN[i] for i in eachindex(LN)]

m = Model(GLPK.Optimizer)

h = 1:length(WF_Prod)
i = 1:length(Pi_max)
j = 1:length(D_FirstHour)

@variable(m, W[h])
@variable(m, P[i])
@variable(m, D[j])



# Constraints
@constraint(m, [k in h], 0 <= W[k] <= WF_Prod[k])
@constraint(m, [k in i], 0 <= P[k] <= Pi_max[k])
@constraint(m, [k in j], 0 <= D[k] <= D_FirstHour[k])
# Power Balance constraint
power_balance = @constraint(m,( sum(D[k] for k in j) - sum(P[k] for k in i) - sum(W[k] for k in h))*(-1) == 0)

@objective(m, Max, sum(D[k] * Dp[k] for k in j) - sum(P[k] * Ci[k] for k in i)) # Objective function. Wind energy not included since cost is assumed to be zero


optimize!(m)


if termination_status(m) == MOI.OPTIMAL
    println("Objective value: ", JuMP.objective_value(m))
# Extract and print optimal values for wind farms
for i in eachindex(W)
    println("W[$i] = ", JuMP.value(W[i]))
end
# Extract and print optimal values for x1
    for i in eachindex(P)
        println("P[$i] = ", JuMP.value(P[i]))
    end

# Extract and print optimal values for x2
    for j in eachindex(D)
        println("D[$j] = ", JuMP.value(D[j]))
    end
    # Compute and print maximised social welfare
    println("Optimised social welfare: ", JuMP.objective_value(m))
    # Compute and print Market Clearing Price (MCP)
    MCP = round(JuMP.dual(power_balance), digits=2)
    println("Market Clearing Price (MCP): ", MCP)
    # Compute and print profits per wind farm
    println("\nProfits per wind farm: ")
    for i in 1:length(WF_Prod)
        profit = (MCP) * JuMP.value(W[i]) # What is the cost of wind energy?
        println("Profit of Wind Farm $i = ", profit)
    end
    # Compute and print profits per generator
    println("\nProfits per generator: ")
    for i in 1:length(Pi_max)
        profit = (MCP - Ci[i]) * JuMP.value(P[i])
        println("Profit of Generator $i = ", profit)
    end
    # Compute and print utility per demand
    for j in 1:length(D)
        utility_j = JuMP.value(D[j]) * (Dp[j] - MCP)
        println("Utility of Demand $j: ", utility_j)
    end

else
    println("Optimize was not successful. Return code: ", termination_status(m))
end

#################### making supply/demand curves for the report ##################
using PyPlot
PyPlot.svg(true)  # Enable SVG backend for better plot rendering

demand_prices = Dp  # Demand bid prices ($/MWh)
demand_quantities = D_FirstHour  # Corresponding demand quantities (MWh)

supply_quantities = vcat(Pi_max, WF_Prod) # combine the production capacities of the generators and the wind farm
supply_costs = vcat(Ci, zeros(length(WF_Prod))) # combine the production costs of the generators and the wind farm

# Sort demand from highest to lowest (forms downward-sloping demand curve)
sorted_demand = sortperm(demand_prices, rev=true)
demand_prices = demand_prices[sorted_demand]
demand_quantities = demand_quantities[sorted_demand]

# Sort supply from lowest to highest (forms upward-sloping supply curve)
sorted_supply = sortperm(supply_costs)
supply_costs = supply_costs[sorted_supply]
supply_quantities = supply_quantities[sorted_supply]

# Compute cumulative quantities
cumulative_demand = cumsum(demand_quantities)
cumulative_supply = cumsum(supply_quantities)
println(cumulative_demand)

# Plot the curves using PyPlot
figure(figsize=(7,5))
#plot(cumulative_demand, demand_prices, marker="o", linestyle="-", color="red", label="Demand Curve")
#plot(cumulative_supply, supply_costs, marker="s", linestyle="-", color="blue", label="Supply Curve")
# Demand curve (stepwise with right angles)
plot(cumulative_demand, demand_prices, drawstyle="steps-post", marker="o", linestyle="-", color="orange", label="Demand")
# Supply curve (stepwise with right angles)
plot(cumulative_supply, supply_costs, drawstyle="steps-post", marker="o", linestyle="-", color="blue", label="Supply")
xlabel("Quantity (MW)")
ylabel("Price (\$/MW)")
title("Energy Market Supply & Demand")
legend(loc="best")
grid(true)
gcf()  # Show current figure
# savefig("supply_demand_curves.svg")  # Save figure to file