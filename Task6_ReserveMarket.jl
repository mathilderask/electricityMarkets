#Task6_ReserveMarket

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
Ci_U = df_GUD[!, :"Ci_+"]  # Up regulation offer price of conventional generators
Ci_D = df_GUD[!, :"Ci_-"]  # Down regulation offer price of conventional generators
Ri_plus = df_GUD[!, :"Ri_+"]  # Maximum up reserve capacity of conventional generators
Ri_minus = df_GUD[!, :"Ri_-"]  # Maximum down reserve capacity of conventional generators
Di = df_LP[!, "System_demand_(MW)"]  # Load profile
LN = df_LN[!, :"Percentage_SystemLoad"]  # Load node percentages
Dp = df_DB[!, :]  # Demand price bids for each hour
WF_Prod = df_WP[!, :] # Wind farm production for each hour

#------------------------------------Reserve Market Clearance------------------------------------#

# Initialize the model
m_reserve = Model(GLPK.Optimizer)


T = 1:24
G = 1:length(Pi_max) # Number of conventional generators
G_reserve = 1:length(Pi_max) # Generators participating in the reserve market (added as a separate list in case some generators do not participate)

# Define variables
@variable(m_reserve, r_U[G, T] >= 0)   # Upward reserve
@variable(m_reserve, r_D[G, T] >= 0)   # Downward reserve

#Constraints
for t in T
    #Reserve service requirements
    hourly_up_reserve = Di[t] * 0.15
    hourly_down_reserve = Di[t] * 0.10

    #Constraints
    @constraint(m_reserve, sum(r_U[g, t] for g in G_reserve) == hourly_up_reserve)
    @constraint(m_reserve, sum(r_D[g, t] for g in G_reserve) == hourly_down_reserve)

    for g in G_reserve
        @constraint(m_reserve, r_U[g, t] <= Ri_plus[g])
        @constraint(m_reserve, r_D[g, t] <= Ri_minus[g])
        @constraint(m_reserve, r_U[g, t] + r_D[g, t] <= Pi_max[g])
    end
end

#Objective function
@objective(m_reserve, Min, sum(r_U[g, t] * Ci_U[g] + r_D[g, t] * Ci_D[g] for g in G_reserve, t in T))

# Solve the model
optimize!(m_reserve)

# Extract results
if termination_status(m_reserve) == MOI.OPTIMAL
    println("Total Reserve Cost: ", round(objective_value(m_reserve), digits=2))

    total_rU_per_gen = [sum(value(r_U[g, t]) for t in T) for g in G]
    total_rD_per_gen = [sum(value(r_D[g, t]) for t in T) for g in G]

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


I = 1:length(Pi_max)
J = 1:length(LN)
H = 1:size(WF_Prod, 2)

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
optimize!(m)

# Extracting the results
if termination_status(m) == MOI.OPTIMAL
    # Extract market-clearing prices
    MCPs = [shadow_price(power_balance[t]) for t in T]

    # Compute total profits for conventional generators
    gen_profits = [sum((value(P[i, t]) * MCPs[t]) - (value(P[i, t]) * Ci[i]) for t in T) for i in I]
    
    # Compute Total Profits per Wind Farm (assuming zero marginal cost)
    wind_profits = [sum(value(W[h, t]) * MCPs[t] for t in T) for h in H]

    #Print results

    println("Total social welfare: ", round(objective_value(m), digits=2))
    println("Market Clearing Prices per hour: ", [round(MCPs[t], digits=2) for t in T])
    println("Total Profits per Conventional Generator: ", [round(p, digits=2) for p in gen_profits])
    println("Total Profits per Wind Farm: ", [round(w, digits=2) for w in wind_profits])
    
    #Print dispatch of conventional units and BESS
    total_power_per_generator = [sum(value(P[i, t]) for t in T) for i in I]
    println("Total power delivered by each conventional generator (MWh): ", [round(p, digits=2) for p in total_power_per_generator])

    
else
    println("Optimization failed: ", termination_status(m))
end

