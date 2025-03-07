# Task 2 test
using Pkg
Pkg.add("CSV")
Pkg.add("DataFrames")
Pkg.add("JuMP")
Pkg.add("GLPK")

using CSV, DataFrames, JuMP, GLPK

# Read CSV files and specify column types to ensure Float64 conversion
df_GUD = CSV.read("GeneratingUnitsData.csv", DataFrame; delim=';', types=Dict(:Pi_max => Float64, :Ci => Float64))
df_LP = CSV.read("LoadProfile.csv", DataFrame; delim=';', types=Dict(Symbol("System_demand_(MW)") => Float64))
df_LN = CSV.read("LoadNodes.csv", DataFrame; delim=';', types=Dict(:Percentage_SystemLoad => Float64))
df_WP = CSV.read("WindProdHour.csv", DataFrame; delim=';')
df_DB = CSV.read("DemandBidHour.csv", DataFrame; delim=';')

# Extract data directly as Float64
Pi_max = df_GUD[!, :"Pi_max"]  # Maximum power output of conventional generators
Ci = df_GUD[!, :"Ci"]          # Production cost of conventional generators
Di = df_LP[!, "System_demand_(MW)"]  # Load profile
LN = df_LN[!, :"Percentage_SystemLoad"]  # Load node percentages
Dp = df_DB[!, :]  # Demand price bids for each hour
WF_Prod = df_WP[!, :] # Wind farm production for each hour


# Initialize variables to store results
MCPs = Float64[]
total_social_welfare = 0.0
total_profits_generators = zeros(Float64, length(Pi_max))
total_profits_windfarms = zeros(Float64, size(WF_Prod, 2))

# Initialize variables to store results
global MCPs = Float64[]
global total_social_welfare = 0.0
global total_profits_generators = zeros(Float64, length(Pi_max))
global total_profits_windfarms = zeros(Float64, size(WF_Prod, 2))

for hour in 1:24
    # Compute the load for each node in the current hour
    D_CurrentHour = [Di[hour] * LN[i] for i in 1:length(LN)]
    
    # Create the optimization model
    m = Model(GLPK.Optimizer)
    
    h = 1:size(WF_Prod,2)
    i = 1:length(Pi_max)
    j = 1:length(D_CurrentHour)
    
    # Variables for wind farm generation (W), conventional generator production (P), and demand (D)
    @variable(m, W[h])  # Wind farm generation
    @variable(m, P[i])  # Conventional generator production
    @variable(m, D[j])  # Demand at each node
    

    # Constraints
    @constraint(m, [k in h], 0 <= W[k] <= WF_Prod[hour, k])  # Wind power output limits
    @constraint(m, [k in i], 0 <= P[k] <= Pi_max[k])          # Generator power output limits
    @constraint(m, [k in j], 0 <= D[k] <= D_CurrentHour[k])    # Demand limits for each node

    # Power balance constraint: System demand = power from generators + wind farms
    power_balance = @constraint(m, (sum(D[k] for k in j) - sum(P[k] for k in i) - sum(W[k] for k in h)) * (-1) == 0)

    # Objective function: Maximize social welfare
    @objective(m, Max, sum(D[k] * Dp[hour, k] for k in j) - sum(P[k] * Ci[k] for k in i))

    # Optimize the model
    optimize!(m)

    if termination_status(m) == MOI.OPTIMAL
        # Market clearing price
        MCP = round(JuMP.dual(power_balance), digits=2)
        push!(MCPs, MCP)
        global total_social_welfare += JuMP.objective_value(m)

        # Compute and store profits per wind farm
        for k in 1:length(WF_Prod[hour, :])
            global total_profits_windfarms[k] += MCP * JuMP.value(W[k])
        end

        # Compute and store profits per generator
        for k in 1:length(Pi_max)
            global total_profits_generators[k] += (MCP - Ci[k]) * JuMP.value(P[k])
        end        
    else
        println("Optimize was not successful for hour $hour. Return code: ", termination_status(m))
    end
end

# Print results
println("Market Clearing Prices (MCP) per hour: ", MCPs)
println("Total Social Welfare for 24 hours: ", total_social_welfare)
println("Total Profits per Generator: ", total_profits_generators)
println("Total Profits per Wind Farm: ", total_profits_windfarms)






