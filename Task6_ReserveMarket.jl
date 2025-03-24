#Task6: Reserve Market clearance 

#------------------------------------Input Data and File Reading------------------------------------#

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
Ri_U = df_GUD[!, :"Ri_U"]  # Ramp up rate
Ri_D = df_GUD[!, :"Ri_D"]  # Ramp down rate
Pini = df_GUD[!, :"Pi_ini"]  # Initial power output of conventional generators when t=0
Ci_plus = df_GUD[!, :"Ci_+"]  # Up regulation offer price of conventional generators
Ci_minus = df_GUD[!, :"Ci_-"]  # Down regulation offer price of conventional generators
Ci_U = df_GUD[!, :"Ci_u"]  # Upward reserve capacity cost of generating unit
Ci_D = df_GUD[!, :"Ci_d"]  # Downward reserve capacity cost of generating unit
Ri_plus = df_GUD[!, :"Ri_+"]  # Maximum up reserve capacity of conventional generators
Ri_minus = df_GUD[!, :"Ri_-"]  # Maximum down reserve capacity of conventional generators
Di = df_LP[!, "System_demand_(MW)"]  # Load profile
LN = df_LN[!, :"Percentage_SystemLoad"]  # Load node percentages
Dp = df_DB[!, :]  # Demand price bids for each hour
WF_Prod = df_WP[!, :] # Wind farm production for each hour

#------------------------------------Reserve Market Clearance------------------------------------#

# Initialize the model
m_reserve = Model(GLPK.Optimizer)


T = 1:24 # Set of time periods (hours in the day-ahead market: 1 to 24)
G = 1:length(Pi_max) # Number of conventional generators
G_reserve = 1:length(Pi_max) # Generators participating in the reserve market (added as a separate list in case some generators do not participate)

# Define variables
@variable(m_reserve, r_U[G, T] >= 0)   # Upward reserve
@variable(m_reserve, r_D[G, T] >= 0)   # Downward reserve

#Constraints
@constraint(m_reserve, up_reserve[t in T], sum(r_U[g, t] for g in G_reserve) == Di[t] * 0.15)
@constraint(m_reserve, down_reserve[t in T], sum(r_D[g, t] for g in G_reserve) == Di[t] * 0.10)

for t in T
    for g in G_reserve
        @constraint(m_reserve, r_U[g, t] <= Ri_plus[g])
        @constraint(m_reserve, r_D[g, t] <= Ri_minus[g])
        @constraint(m_reserve, r_U[g, t] + r_D[g, t] <= Pi_max[g])
    end
end

#Objective function
@objective(m_reserve, Min, sum(r_U[g, t] * Ci_plus[g] + r_D[g, t] * Ci_minus[g] for g in G_reserve, t in T))

# Solve the model
@time optimize!(m_reserve)

#------------------------------------Results and Output (Reserve Market)--------------------------------#

# Extract results
if termination_status(m_reserve) == MOI.OPTIMAL
    # Total reserve per generator (Upward and Downward)
    total_rU_per_gen = [sum(value(r_U[g, t]) for t in T) for g in G]
    total_rD_per_gen = [sum(value(r_D[g, t]) for t in T) for g in G]

    # Reserve market shadow prices (dual values of reserve constraints)
    up_reserve_prices = -[shadow_price(up_reserve[t]) for t in T]
    down_reserve_prices = -[shadow_price(down_reserve[t]) for t in T]

    # Calculate reserve market profit per generator (including Downward and Upward reserve profits)
    gen_reserve_profits = [sum(value(r_U[g, t]) * (up_reserve_prices[t] - Ci_U[g]) + value(r_D[g, t]) * (down_reserve_prices[t] - Ci_D[g]) for t in T) for g in G]

    # Print results
    println("Reserve Market Profits per Generator: ", [round(p, digits=2) for p in gen_reserve_profits])
    println("Upward Reserve Prices per Hour: ", [round(p, digits=2) for p in up_reserve_prices])
    println("Downward Reserve Prices per Hour: ", [round(p, digits=2) for p in down_reserve_prices])
    println("Total Reserve Cost: ", round(objective_value(m_reserve), digits=2))
    println("Total Upward Reserve per Generator (MWh): ", [round(x, digits=2) for x in total_rU_per_gen])
    println("Total Downward Reserve per Generator (MWh): ", [round(x, digits=2) for x in total_rD_per_gen])
else
    println("Reserve Market optimization failed: ", termination_status(m_reserve))
end

# Store the reserve results for Day-Ahead Market Clearance
r_up = [value(r_U[g, t]) for g in G, t in T] #Saving upward reserve results 
r_down = [value(r_D[g, t]) for g in G, t in T] #Saving downward reserve results 


#------------------------------------Day-Ahead Market Clearance------------------------------------#

# Initialize the model
m = Model(GLPK.Optimizer)


I = 1:length(Pi_max) # Set of conventional generators (indexed based on the total number of generators)
J = 1:length(LN) # Set of demand nodes (indexed based on the number of load nodes in the system)
H = 1:size(WF_Prod, 2) # Set of wind farms (indexed based on the number of wind farms in the production data)

# Define variables
@variable(m, 0 <= P[I, T])
@variable(m, 0 <= W[H, T])
@variable(m, 0 <= D[J, T])

# Power balance constraint
@constraint(m, power_balance[t in T], sum(D[j, t] for j in J) - sum(P[i, t] for i in I) - sum(W[h, t] for h in H) == 0)

# Constraints
for t in T
    D_CurrentHour = [Di[t] * LN[j] for j in J]

    # Conventional generators and wind power constraints
    for i in I
        @constraint(m, r_down[i, t] <= P[i, t] <= Pi_max[i] - r_up[i, t])
    end
    for h in H
        @constraint(m, W[h, t] <= WF_Prod[t, h])
    end
    for j in J
        @constraint(m, D[j, t] <= D_CurrentHour[j])
    end

    # Ramp constraints for conventional generators
    if t == 1
        for i in I
            @constraint(m, P[i, t] - Pini[i] <= Ri_U[i])
            @constraint(m, P[i, t] - Pini[i] >= -Ri_D[i])
        end
    else
        for i in I
            @constraint(m, P[i, t] - P[i, t - 1] <= Ri_U[i])
            @constraint(m, P[i, t] - P[i, t - 1] >= -Ri_D[i])
        end
    end
end

# Objective: Maximize total social welfare over all hours
@objective(m, Max, sum(D[j, t] * Dp[t, j] for j in J, t in T) - sum(P[i, t] * Ci[i] for i in I, t in T))

# Solve the model
@time optimize!(m)

#------------------------------------Results and Output (Day-Ahead Market)--------------------------------#

# Extracting the results
if termination_status(m) == MOI.OPTIMAL
    # Extract market-clearing prices
    MCPs = [shadow_price(power_balance[t]) for t in T]

    # Compute day-ahead profits for conventional generators and total profits
    gen_DA_profits = [sum((value(P[i, t]) * MCPs[t]) - (value(P[i, t]) * Ci[i]) for t in T) for i in I]
    gen_total_profits = [gen_DA_profits[g] + gen_reserve_profits[g] for g in G]
    
    # Compute Total Profits per Wind Farm (assuming zero marginal cost)
    wind_profits = [sum(value(W[h, t]) * MCPs[t] for t in T) for h in H]

    #Print results
    println("Total social welfare: ", round(objective_value(m), digits=2))
    println("Market Clearing Prices per hour: ", [round(MCPs[t], digits=2) for t in T])
    println("Day-Ahead profits per Conventional Generator: ", [round(p, digits=2) for p in gen_DA_profits])
    println("Overall profits per Conventional Generator: ", [round(p, digits=2) for p in gen_total_profits])
    println("Total Profits per Wind Farm: ", [round(w, digits=2) for w in wind_profits])
else
    println("Optimization failed: ", termination_status(m))
end

