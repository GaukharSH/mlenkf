# MLEnKF.jl #

This package provides a Julia language implementation of the multilevel ensemble Kalman filtering (MLEnKF) method with the comparison to the ensemble Kalman filtering method (EnKF). 

The code was tested in Julia 1.2.

> Requirements: Julia 1.2

If you have already installed Julia 1.2, then skip to the **Step 2** under *Installation*. 


## Installation

1. Install [Julia 1.2](https://julialang.org/downloads/) following the installation steps on its website. 
2. Download and save [mlenkf.jl](https://github.com/GaukharSH/mlenkf.jl) in your desired location.
3. Open a terminal and `cd` to the location of `mlenkf.jl`.
4. In the command line type 

    **julia>** `include("mlenkf.jl")`
    
    It might need certain packages to install, then you have to run
    
    **julia>** `Pkg.add("TheRequestedPkgName")`


## Usage

1. The code is written for the test problems with Ornstein-Uhlenbeck and Double-well SDEs. In the code script, you can choose one of these problems, set the parameters (See "### DOUBLE WELL PROBLEM" and "### OU PROBLEM" in the code for where to comment/uncomment for the respective problems) or you can test other problems with the  constant diffusion stochastic dynamics by altering the potential function in the drift term. If you have made some changes in `mlenkf.jl` file, repeat the **Step 4** under *Installation*.
2. Now run the code which computes the reference solution, runtime (wall-clock time) and time-averaged root mean-squared error (RMSE) of both EnKF and MLEnKF (for detailed information see Section 3 of the manuscript).

    **julia>** `testEstimatorRates()`
    
It should produce terminal text output similar to the following:
    
 ```
     Done computing refSol
     Enkf [epsilon time error ] : [0.0625 0.24664124534999998 0.007217082197351228]
     Enkf [epsilon time error ] : [0.0625 0.0345881389 0.007217082197351228]
     Enkf [epsilon time error ] : [0.03125 0.2570247531 0.0036709007780499742]
     Enkf [epsilon time error ] : [0.015625 2.0834773806 0.001794714358291246]
     Enkf [epsilon time error ] : [0.0078125 16.2812260163 0.000896078483155702]
     Enkf [epsilon time error ] : [0.00390625 129.2634632314 0.00044670579542082186]
     Enkf [epsilon time error ] : [0.001953125 1023.670913695 0.0002309035587358585]
     Enkf [epsilon time error ] : [0.0009765625 8200.5335342226 0.00011339808662888725]
     [288, 72, 18, 4]
     MLEnkf [epsilon time error ] : [0.0625 0.16208511045000001 0.013894476423322265]
     [288, 72, 18, 4]
     MLEnkf [epsilon time error ] : [0.0625 0.028666037900000003 0.013894476423322265]
     [2048, 512, 128, 32, 8]
     MLEnkf [epsilon time error ] : [0.03125 0.23579944275 0.0054837202493686794]
     [12800, 3200, 800, 200, 50, 12]
     MLEnkf [epsilon time error ] : [0.015625 1.6000000002 0.0021447782422146476] 
     [73728, 18432, 4608, 1152, 288, 72, 18]
     MLEnkf [epsilon time error ] : [0.0078125 10.010947965600002 0.0009870749904232344]
     [401408, 100352, 25088, 6272, 1568, 392, 98, 24]
     MLEnkf [epsilon time error ] : [0.00390625 58.3044512289 0.00043149069742411795]
     [2097152, 524288, 131072, 32768, 8192, 2048, 512, 128, 32]
     MLEnkf [epsilon time error ] : [0.001953125 322.19146874060004 0.00020264552725186543]
     [10616832, 2654208, 663552, 165888, 41472, 10368, 2592, 648, 162, 40]
     MLEnkf [epsilon time error ] : [0.0009765625 1689.39035685455 9.219596479159126e-5]
     [52428800, 13107200, 3276800, 819200, 204800, 51200, 12800, 3200, 800, 200, 50]
     MLEnkf [epsilon time error ] : [0.00048828125 8762.05635155385 4.332970311781636e-5]   
```
    
where for both EnKF and MLEnKF, the first column shows the tolerance inputs, the     second column refers to runtime and the last one is for RMSE of the mean. The       lines above MLEnKF show the decreasing sequence of Monte Carlo sample sizes    used, respevtively, at each level in MLEnKF given the epsilon-input value. 
    
The above command also saves the measurement series, the underlying truth, runtime, the abstract cost, the time-averaged RMSE of mean and covariance for both EnKF and MLEnKF, respectively, in files `enkf$(problemText)_T$(T).jld`  and `mlenkf$(problemText)_T$(T).jld`, according to the chosen problem and the simulation length. The files will be saved in the same folder of `mlenkf.jl`.
   
3.  In order to plot the results on convergence rates of the methods, run the following:
 
    **julia>** `plotResults("enkf$(problemText)_T$(T).jld","mlenkf$(problemText)_T$(T).jld")`
    
    according to saved file names. For example, $(problemText)="DoubleWell" and $(T)="20". This provides convergence rates of mean in Figure 2 and covariance in Figure 3, comparing the performance of EnKF and MLEnKF methods in terms of runtime vs RMSE. 

4. Note also that the program runs in parallel. The number of workers is set in the beginning of the code by "const parallel_procs = 6;" (where we observe that only 5 are 100% active during long computations). Due to the parallelism, care has been taken to employ non-overlapping random seeds on different parallel processes through the function "Future.randjump()". Parallel computations are executed through the "pmap" function. The estimation of wall-clock runtime is done as follows for EnKF (and analogously for MLEnKF):

```
const parallel_procs = 6;
if nprocs()<parallel_procs
    addprocs(parallel_procs -nprocs());
end
const workers = nprocs()-1;
...
timeEnkf = @elapsed output = pmap(rng -> EnKF(N, P, y, rng), rngSeedVec); #Time it takes for 'workers' many parallel processes 
																		  #to compute all EnKF runs
...
timeEnkf*= workers/numRuns; #this is equal to the average time it takes for one worker/process to compute one EnKF run
```

## Reference

The algorithm implemented in this package is based on the manuscript 

*"Multilevel Ensemble Kalman Filtering with local-level Kalman Gains"*

by H.Hoel, G.Shaimerdenova and R.Tempone, 2019 (to appear on ArXiv).
