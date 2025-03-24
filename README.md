# Assignment 1 (Course: 46755) - Spring 2025 - Group 8

### Overview
This repository contains various scripts and datasets related to electricity market modeling and analysis based on 
"An Updated Version of the IEEE RTS 24-Bus System for Electricity Market and Power System Operation Studies" by 
Christos Ordoudis, Pierre Pinson, Juan M. Morales, and Marco Zugno. 

### Directory structure
- Task 1.jl
- DemandBidHour.csv
- GeneratingUnitsData.csv
- LoadNodes.csv
- LoadProfile.csv
- Task 2 w_BESS.jl
- Task 2 wo_BESS.jl
- Task 3 nodal sensitivity analysis
- Task 3 zonal
- Task5_BalancingMarket.jl
- Task6_ReserveMarket.jl
- TransmissionLineDataV2.csv
- WindFarmData.csv
- WindProdHour.csv
- ZoneData.csv
- ZoneTransfers.csv

### Datasets
- [Demand Bid Hour]: Contains demand bid data for each hour in the 24-hour periodin the market simulation.
- [Generating Units Data]: Includes all the technical and economic parameters of conventional generators, such as maximum power output, costs, and ramp rates.
- [Load Nodes]: Defines the distribution of system demand across different nodes.
- [Load Profile]:  Provides hourly demand values in the system.
- [Transmission Line Data]: Contains all technical data related to the transmission network.
- [Wind Farm Data]: General data from the wind farms in the model.
- [Wind Production Hour]: Hourly production of the wind farms in the model
- [Zone Data]: Data related to power market zones 
- [Zone Transfers]: Power transfers between zones 

### Files
- [Task 1.jl]: This script is the intial setup for the supply and demand for the system. 
- [Task 2 w_BESS.jl]: This script models the day-ahead electricity market over a 24-hour period with a battery energy storage system (BESS). The objective of the model is maximizing total social welfare.
- [Task 2 wo_BESS.jl]: This script models the day-ahead electricity market over a 24-hour period without a battery energy storage system (BESS). The objective of the model is maximizing total social welfare.
- [Task 3_nodal sensitivity analysis]: Nodal price sensitivity analysis
- [Task 3 zonal]: Zonal-level market analysis 
- [Task 4]: Written about in report PDF
- [Task 5_BalancingMarket.jl]: This script models the balancing market for the scenario where there is an outtage in Generator 8 and wind production differs, following the one-price and two-price scheme, respectively.
- [Task6_ReserveMarket.jl]: This script models the reserve market following the European practice, clearing reserves before the day-ahead energy market.

### How to Run
1. Ensure Julia and required packages (JuMP, GLPK, CSV, DataFrames, Plots) are installed.
2. Place all dataset files in the same directory as the scripts.
3. After completing the preceding steps, the .jl files should be fully functional without any issues.

For further questions you can contact us in the following emails:

Jasmin Heckscher - s203674@dtu.dk \\
Mathilde Rasksen - s214258@dtu.dk \\
Alexandra Schonrock - s242818@dtu.dk \\
Diego Fernández - s243091@dtu.dk \\
