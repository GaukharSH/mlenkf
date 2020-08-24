# MLEnKF.jl #

This package provides a Julia language implementation of the multilevel ensemble Kalman filtering (MLEnKF) method with the comparison to the ensemble Kalman filtering method (EnKF). 

The code was tested in Julia 1.2 and Julia 1.3.

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
2. Now run the code which computes the reference solution, runtime (wall-clock time) and time-averaged root mean-squared error (RMSE) of EnKF, MLEnKF and "canonical" MLEnKF (for detailed information see Section 3 of the manuscript).

    **julia>** `testEstimatorRates()`
    
It should produce terminal text output similar to the following:
    
 ```
     Done computing refSol
Enkf [epsilon time error ] : [0.0625 0.22190507115000002 0.006866025020036514]
Enkf [epsilon time error ] : [0.0625 0.0158639021 0.006866025020036514]
Enkf [epsilon time error ] : [0.03125 0.12340077635 0.00339078690071165]
Enkf [epsilon time error ] : [0.015625 0.9667059474 0.0016853284992842702]
Enkf [epsilon time error ] : [0.0078125 7.3135008489 0.0008367767416247611]
[576, 72, 18, 4]
MLEnkf [epsilon time error ] : [0.0625 0.1502902901 0.00547938430125431]
[576, 72, 18, 4]
MLEnkf [epsilon time error ] : [0.0625 0.04212924405 0.00547938430125431]
[4096, 512, 128, 32, 8]
MLEnkf [epsilon time error ] : [0.03125 0.3611851109 0.0023997250740173414]
[25600, 3200, 800, 200, 50, 12]
MLEnkf [epsilon time error ] : [0.015625 1.9472727372000003 0.0010039275557990831]
[147456, 18432, 4608, 1152, 288, 72, 18]
MLEnkf [epsilon time error ] : [0.0078125 11.353462192150001 0.0004566887242892649]
[4064, 1613, 640, 254]
MLEnkfOld [epsilon time error ] : [0.0625 0.0632622617 0.006403888429167188]
[4064, 1613, 640, 254]
MLEnkfOld [epsilon time error ] : [0.0625 0.01649346435 0.006403888429167188]
[8127, 3225, 1280, 508]
MLEnkfOld [epsilon time error ] : [0.04419417382415922 0.0331601732 0.0050108369037795315]
[16255, 6451, 2560, 1016, 403]
MLEnkfOld [epsilon time error ] : [0.03125 0.07474010525000001 0.0031641627969508325]
[32510, 12902, 5120, 2032, 806, 320]
MLEnkfOld [epsilon time error ] : [0.02209708691207961 0.1672994725 0.0021730197489996995]
[65020, 25803, 10240, 4064, 1613, 640]
MLEnkfOld [epsilon time error ] : [0.015625 0.37129062385 0.0016331006610236848]
[130040, 51606, 20480, 8127, 3225, 1280]
MLEnkfOld [epsilon time error ] : [0.011048543456039806 0.8915220689500001 0.001305477761614795]
[260080, 103213, 40960, 16255, 6451, 2560, 1016]
MLEnkfOld [epsilon time error ] : [0.0078125 2.2448837658 0.0007969699997406812]
```
    
where for all EnKF, MLEnKF and "canonical" MLEnKF, the first column shows the tolerance inputs, the  second column refers to runtime and the last one is for RMSE of the mean. The lines above MLEnKF and "old" MLEnKF show the decreasing sequence of Monte Carlo sample sizes used, respectively, at each level in MLEnKF given the epsilon-input value. 
    
The above command also saves the measurement series, the underlying truth, runtime, the abstract cost, the time-averaged RMSE of mean and covariance for all EnKF, MLEnKF and "canonical" MLEnKF, respectively, in files `enkf$(problemText)_T$(T).jld` , `mlenkfOld$(problemText)_T$(T).jld` and `mlenkf$(problemText)_T$(T).jld`, according to the chosen problem and the simulation length. The files will be saved in the same folder of `mlenkf.jl`.
   
3.  In order to plot the results on convergence rates of the methods, run the following:
 
    **julia>** `plotResults("enkf$(problemText)_T$(T).jld","mlenkfOld$(problemText)_T$(T).jld","mlenkf$(problemText)_T$(T).jld")`
    
    according to saved file names. For example, $(problemText)="DoubleWell" and $(T)="20". This provides convergence rates of mean in Figure 2 and covariance in Figure 3, comparing the performance of EnKF and MLEnKF methods in terms of runtime vs RMSE. The reference triangle parameters should be adjusted according to each simulation by altering the respective lines in function `plotResults` of `mlenkf.jl` file.

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
