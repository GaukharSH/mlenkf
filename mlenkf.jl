############### Introduction #################

# Tested in Julia 1.2 and Julia 1.3. NB Julia 1.3 performs much slower than 1.2 for this code.
# It might relate to issues regarding thread-local random number generators: 
#
# (thread-locality should not matter for/improve this program as we implement parallel
# random number generation through passing different instances of rng objects
# that are non-overlappingly seeded to the different parallel processes).

# If having problems importing packages, one suggestion
## -- AT, OF COURSE, YOUR OWN RESPONSIBILITY -- 
# is to wipe clean your julia installation (removing all previously
# imported packages etc.) by calling the following command in a terminal (for Linux and OSX)
# $rm -rf ~/.julia

###########  end introduction ##############


import Pkg
# Add all packages in first run 
Pkg.add("PyPlot")
Pkg.add("JLD")
Pkg.add("LaTeXStrings")
Pkg.add("DSP")#digital signal processing for the convolution function
Pkg.add("Dierckx")
Pkg.add("Distributions")
Pkg.add("BenchmarkTools")

using Distributed
const parallel_procs = 6;
if nprocs()<parallel_procs
    addprocs(parallel_procs -nprocs());
end
const workers = nprocs()-1;
@everywhere using Distributed

using SparseArrays
using SuiteSparse
using BenchmarkTools
using Dierckx #Spline1D needs this library
using LinearAlgebra
using LaTeXStrings
using DSP
@everywhere using Random
@everywhere using Distributions
using PyPlot

using JLD
using SharedArrays
import Future.randjump
#NB In Nov 2019 on Julia 1.2: The previously loaded "Using Distributed.Future" will be in conflict
# with "import Future". Therefore, we only call "import Future.randjump()" from Future (this function is needed to skip ahead in
# random number generator objects). 

rcParams = PyPlot.PyDict(PyPlot.matplotlib."rcParams")
rcParams["font.size"] = 14

#pyplot(guidefont=font, xtickfont=font, ytickfont=font, legendfont=font)
#Plots.scalefontsizes(2)

### DEFINING THE PROBLEM WITH GLOBAL PARAMETERS BELOW 
# Problem potential, derivative (i.e. sde drift coefficient)...
# if considering the OU problem instead of the double well, please comment
# the four lines for DOUBLE WELL PROBLEM below, and uncomment the
# corresponding four lines for OU PROBLEM

### DOUBLE WELL PROBLEM 
#const problemText="DoubleWell";
#V(x)      = @. (2/(1+2*x^2) + x^2)/4;
#@everywhere dVdx(x)   = @. (-8*x/((1+2*x^2)^2) .+ 2*x)/4;
#d2Vd2x(x) = @. ((-8+32*x^2+96*x^4)/(1+2*x^2)^4+2)/4;

### OU PROBLEM 
const problemText = "OrnsteinUhlenbeck"
V(x)      = @. x^2/2;
@everywhere dVdx(x)   = @. x;
d2Vd2x(x) = @. 1.;

# Problem parameters (made global and fixed and constant)
@everywhere const sigma=0.5;
@everywhere const Gamma=0.1;
@everywhere const u0=0.;
@everywhere const H=1;
@everywhere const tau=1;
@everywhere const T=10;
@everywhere const nobs = round(Int,T/tau)+1;
#


function testEstimatorRates()

    ### GENERATING ONE UNDERLYING PATH u and measurement series y
    rng = MersenneTwister(43231242);
    u = zeros(nobs); y   = zeros(nobs);

    if problemText=="DoubleWell"
        u,y = generatePathAndObservations_DW(rng);
        m,c = computePseudoRefSol_DW(y);
    elseif problemText=="OrnsteinUhlenbeck"
        u,y= generatePathAndObservations_OU(rng);
        m,c = computeRefSol_OU(y);
    end
    println("Done computing refSol");
    numRuns = 100; #runs/realizations of enkf and mlenkf
    
    epsVec = 2. .^(-[ 4 4 5 6 7] );

    #generate a sequence of random seeds for parallel computations spaces
    #that is "numRuns" long and each seed is spaced
    #10^20 draws apart in the cycle
    rngSeedVec = let r = rng
        [r; accumulate(randjump, fill(big(10)^20, numRuns), init=r)]
    end;
    
    # storage of EnKF output
    timeEnkf = zeros(length(epsVec));
    costEnkf = zeros(length(epsVec));
    mEnkf    = zeros(length(epsVec),nobs);
    cEnkf    = zeros(length(epsVec),nobs);
    errMEnkf = zeros(length(epsVec));
    errCEnkf = zeros(length(epsVec));
    
    for i=1:length(epsVec)
        N = round(Int, 1/epsVec[i]);
        P = round(Int, 8*(1/epsVec[i])^2);

        # computing numRuns realizations of enkf in parallel
        timeEnkf[i] = @elapsed output = pmap(rng -> EnKF(N, P, y, rng), rngSeedVec);
        for j=1:numRuns

            mTmp = output[j][1];
            cTmp = output[j][2];
            mEnkf[i,:]+=mTmp/numRuns;
            cEnkf[i,:]+=cTmp/numRuns;
            
	    errMEnkf[i]+= norm(mTmp - m)^2/(nobs*numRuns);
            errCEnkf[i]+= norm(cTmp -c)^2/(nobs*numRuns);	

        end    
        
        timeEnkf[i]*= workers/numRuns;
        errMEnkf[i] = sqrt(errMEnkf[i]);
        errCEnkf[i] = sqrt(errCEnkf[i]);
        costEnkf[i] = P*N;
        println("Enkf [epsilon time error ] : ", [epsVec[i] timeEnkf[i] errMEnkf[i]])
        save("enkf.jld", "u", u, "y", y, "timeEnkf", timeEnkf, "costEnkf", costEnkf, "errMEnkf", errMEnkf, "errCEnkf", errCEnkf);
    end

    # throw away first computation (which due to first-run-JIT-compilation gives an incorrect/too large runtime)
    timeEnkf = timeEnkf[2:end];
    errMEnkf = errMEnkf[2:end];
    errCEnkf = errCEnkf[2:end];
    costEnkf = costEnkf[2:end];
    save("enkf$(problemText)_T$(T).jld", "u", u, "y", y, "timeEnkf", timeEnkf, "costEnkf", costEnkf, "errMEnkf", errMEnkf, "errCEnkf", errCEnkf);

#MLEnKF   
    epsVec = 2. .^(-[4 4 5 6 7] );
    timeMLEnkf = zeros(length(epsVec));
    costMLEnkf = zeros(length(epsVec));
    mMLEnkf = zeros(length(epsVec),nobs);
    cMLEnkf = zeros(length(epsVec),nobs);
    errMMLEnkf = zeros(length(epsVec));
    errCMLEnkf = zeros(length(epsVec));

    for i=1:length(epsVec)
        
        L  = round(Int, log2(1/epsVec[i]))-1;
        Nl = 2*2 .^(0:L);
        Pl = 10*2 .^(0:L);
        Ml = zeros(Int, size(Nl));

        #classic Ml
        for l=1:L+1           
           Ml[l] = round(Int, L^2 *epsVec[i]^(-2)/(Nl[l]^2)/2);
        end
        Ml[1] = 2Ml[1];
        
        timeMLEnkf[i] = @elapsed output = pmap(rng -> MLEnKF(Ml, Nl, Pl, L, y, rng), rngSeedVec);
        for j=1:numRuns

            mTmp = output[j][1];
            cTmp = output[j][2];
            mMLEnkf[i,:]  += mTmp/numRuns;
            cMLEnkf[i,:]  += cTmp/numRuns;
	    errMMLEnkf[i] += norm(mTmp - m)^2/(nobs*numRuns);
            errCMLEnkf[i] += norm(cTmp -c)^2/(nobs*numRuns);	

        end    
        timeMLEnkf[i]*= workers/numRuns;
        errMMLEnkf[i] = sqrt(errMMLEnkf[i]);
        errCMLEnkf[i] = sqrt(errCMLEnkf[i]);
        costMLEnkf[i] = sum(Pl.*Ml.*Nl);
        println(Ml)
        println("MLEnkf [epsilon time error ] : ", [epsVec[i] timeMLEnkf[i] errMMLEnkf[i]])
        save("mlenkf.jld", "u", u, "y", y, "timeMLEnkf", timeMLEnkf, "costMLEnkf",
             costMLEnkf, "errMMLEnkf", errMMLEnkf, "errCMLEnkf", errCMLEnkf);
        

           end
    timeMLEnkf = timeMLEnkf[2:end];
    errMMLEnkf = errMMLEnkf[2:end];
    errCMLEnkf = errCMLEnkf[2:end];
    costMLEnkf = costMLEnkf[2:end];
    
    save("mlenkf$(problemText)_T$(T).jld", "u", u, "y", y, "timeMLEnkf", timeMLEnkf, "costMLEnkf",
         costMLEnkf, "errMMLEnkf", errMMLEnkf, "errCMLEnkf", errCMLEnkf);

#Old MLEnKF 
    epsVec = 2. .^(-[4 4 4.5 5 5.5 6 6.5 7] );
    timeMLEnkfOld = zeros(length(epsVec));
    costMLEnkfOld = zeros(length(epsVec));
    mMLEnkfOld = zeros(length(epsVec),nobs);
    cMLEnkfOld = zeros(length(epsVec),nobs);
    errMMLEnkfOld = zeros(length(epsVec));
    errCMLEnkfOld = zeros(length(epsVec));

    for i=1:length(epsVec)
        
        L  = round(Int, log2(1/epsVec[i]))-1;
        Nl = 2*2 .^(0:L);
        PlOld = zeros(Int, size(Nl));

        for l=1:L+1           
           PlOld[l] = round(Int, 40*epsVec[i]^(-2)/(Nl[l]^(4/3)));
        end
        
         timeMLEnkfOld[i] = @elapsed output = pmap(rng -> MLEnKFOld(Nl, PlOld, L, y, rng), rngSeedVec);
        for j=1:numRuns
            
            mTmp = output[j][1];
            cTmp = output[j][2];
            mMLEnkfOld[i,:]  += mTmp/numRuns;
            cMLEnkfOld[i,:]  += cTmp/numRuns;
	    errMMLEnkfOld[i] += norm(mTmp - m)^2/(nobs*numRuns);
            errCMLEnkfOld[i] += norm(cTmp -c)^2/(nobs*numRuns);	

        end    
        timeMLEnkfOld[i]*= workers/numRuns;
        errMMLEnkfOld[i] = sqrt(errMMLEnkfOld[i]);
        errCMLEnkfOld[i] = sqrt(errCMLEnkfOld[i]);
        costMLEnkfOld[i] = sum(PlOld.*Nl);
        println(PlOld)
        println("MLEnkfOld [epsilon time error ] : ", [epsVec[i] timeMLEnkfOld[i] errMMLEnkfOld[i]])
        save("mlenkfOld.jld", "u", u, "y", y, "timeMLEnkfOld", timeMLEnkfOld, "costMLEnkfOld",
             costMLEnkfOld, "errMMLEnkfOld", errMMLEnkfOld, "errCMLEnkfOld", errCMLEnkfOld);

    end

    timeMLEnkfOld = timeMLEnkfOld[2:end];
    errMMLEnkfOld = errMMLEnkfOld[2:end];
    errCMLEnkfOld = errCMLEnkfOld[2:end];
    costMLEnkfOld = costMLEnkfOld[2:end];
    
    save("mlenkfOld$(problemText)_T$(T).jld", "u", u, "y", y, "timeMLEnkfOld", timeMLEnkfOld, "costMLEnkfOld",
         costMLEnkfOld, "errMMLEnkfOld", errMMLEnkfOld, "errCMLEnkfOld", errCMLEnkfOld);

end


@everywhere function EnKF(N, P, y, rng)

    m = zeros(nobs); c= zeros(nobs);
    m[1] = u0;
    c[1] = Gamma;
    dt   = tau/N;
    
    v = m[1] .+ sqrt(c[1])*randn(rng,P);
    for n=2:nobs
	
	v = Psi(v, N, dt, rng);
	
	c[n]   = cov(v);#Prediction covariance
	K      = c[n]*H/(Gamma+H*c[n]*H);#Kalman gain -- assuming scalar setting
	yTilde = y[n].+ sqrt(Gamma)*randn(rng,P);#perturbed observation
	
        v      = (1-K*H)*v+K*yTilde;#ensemble update
        m[n]   = mean(v);# update mean and covariance 
        c[n]   = cov(v);

    end
    return m,c;
end



@everywhere function MLEnKF(Ml, Nl, Pl, L, y, rng)

    m = zeros(nobs); c= zeros(nobs);
    dtl = tau ./Nl;

    # solve for l=1
    for i=1:Ml[1]
        mTmp, cTmp = EnKF(Nl[1], Pl[1], y, rng);
        m+=mTmp/Ml[1];
        c+=cTmp/Ml[1];
    end
    
    # solve for l>1
    for l=2:L+1
        plHalf = Pl[l-1]; 
        mTmp = zeros(nobs); cTmp= zeros(nobs);
        for i=1:Ml[l]
            
            vF = u0 .+ sqrt(Gamma)*randn(rng,Pl[l]); vC = vF;
	    for n=2:nobs
	        
	        vC,vF = PsiL(vC, vF, Nl[l-1], dtl[l], rng);
	        covF = cov(vF); covC1 = cov(vC[1:plHalf]); covC2 = cov(vC[plHalf+1:end]);
                kF  = covF*H/(H*covF*H + Gamma);
                kC1 = covC1*H/(H*covC1*H + Gamma);
                kC2 = covC2*H/(H*covC2*H + Gamma);
                
                yTilde           = y[n].+ sqrt(Gamma)*randn(rng,Pl[l]);#perturbed observation
	        vF               = (1-kF*H)*vF+kF*yTilde;#ensemble update
                vC[1:plHalf]     = (1-kC1*H)*vC[1:plHalf]+kC1*yTilde[1:plHalf];#
                vC[plHalf+1:end] = (1-kC2*H)*vC[plHalf+1:end]+kC2*yTilde[plHalf+1:end];#
                
                mTmp[n]   += mean(vF-vC)/Ml[l];# update mean and covariance 
                cTmp[n]   += (cov(vF)-(cov(vC[1:plHalf])+cov(vC[plHalf+1:end]))/2.)/Ml[l];
            end
        end
        m +=mTmp; c +=cTmp;
    end
    return m,c;
end


@everywhere function MLEnKFOld(Nl, PlOld, L, y, rng)

    m = zeros(nobs); c= zeros(nobs);
    m[1]=0; c[1]=Gamma;
    dtl = tau ./Nl;
        
    #Initialisation
         vF=Array{Array{Float64,1}}(undef, L+1)
         vC=Array{Array{Float64,1}}(undef, L+1)

         vF[1]=u0 .+ sqrt(Gamma)*randn(rng,PlOld[1]);
         vC[1]=zeros(PlOld[1]);

        for l=2:L+1
          vF[l]=u0 .+ sqrt(Gamma)*randn(rng,PlOld[l]);
          vC[l]=vF[l];
        end

    covF=zeros(nobs);
    for n=2:nobs

    #Prediction step
    for l=1:L+1

        if l==1
        vF[1]=Psi(vF[1], Nl[1], dtl[1], rng); 
        covF[n]=cov(vF[1]);
        else
        vC[l],vF[l] = PsiL(vC[l], vF[l], Nl[l-1], dtl[l], rng);
        covF[n] +=cov(vF[l])-cov(vC[l])
        end
        
       
        #covF +=(l>1)*(cov(vF[l])-cov(vC[l]))+(l==1)*cov(vF[l]);
        #covF =(covF>0)*covF;
 
    end
    covF[n] =(covF[n]>0)*covF[n];
    kF  = covF[n]*H/(H*covF[n]*H + Gamma);
     
    for l=1:L+1
        yTilde = y[n].+ sqrt(Gamma)*randn(rng,PlOld[l]);#perturbed observation
        
        #if l==1
        #eta=yTilde;
        #end

        #Update step
        vF[l]     = (1-kF*H)*vF[l]+kF*yTilde;           
        vC[l]     = (1-kF*H)*vC[l]+kF*yTilde;  
   
        if l==1
        m[n]= mean(vF[l]);
        c[n]= cov(vF[l]);
        else
        m[n]  += mean(vF[l]-vC[l]);
        c[n]  += cov(vF[l])-cov(vC[l]);  
        end
       # m[n]  += (l>1)*(mean(vF[l]-vC[l]))+(l==1)*mean(vF[l]);
       # c[n]  += (l>1)*(cov(vF[l])-cov(vC[l]))+(l==1)*cov(vF[l]);
    end
       #c[n]  = (1-kF*H)*covF+kF*(cov(eta)-Gamma)*kF';
    end

    return m,c;
end



@everywhere function Psi(v, N, dt,rng)

    sqrtDt = sqrt(dt);
    P = length(v);
    if(P<1000)
	for n=1:N
	    v = v -dVdx(v)*dt + sigma*randn(rng,P)*sqrtDt;
    	end
    else
        iter = floor(Int, P/1000);
        pStart=1; pEnd = 1000;
        for k=1:iter
            for n=1:N
                v[pStart:pEnd] = v[pStart:pEnd] -dVdx(v[pStart:pEnd])*dt + sigma*randn(rng,1000)*sqrtDt;
            end
            pStart+=1000; pEnd +=1000;
        end
        
        for n=1:N
            v[pStart:end] = v[pStart:end] -dVdx(v[pStart:end])*dt + sigma*randn(rng,P-pStart+1)*sqrtDt;
        end
    end
    return v;
end

@everywhere function PsiL(vC, vF, nC, dtF, rng)
    # Assuming here that dtC = 2dtF
    sqrtDtF = sqrt(dtF); P = length(vF); dtC = 2*dtF;

    for n=1:nC
        dw1 = randn(rng,P)*sqrtDtF;
        vF  = vF - dVdx(vF)*dtF + sigma*dw1; 
        dw2 = randn(rng,P)*sqrtDtF;
        vF  = vF - dVdx(vF)*dtF + sigma*dw2;
        vC = vC - dVdx(vC)*dtC+ sigma*(dw1+dw2);     
    end

    return vC,vF;
end


function generatePathAndObservations_DW(rng)

    nDt =10000;
    dt = tau/nDt;
    
    y = zeros(nobs); u = zeros(nDt*(nobs-1)+1);
    u[1] = u0;
    y[1] = H*u[1]+ sqrt(Gamma)*randn(rng);
        
    for n=1:(nobs-1)*nDt

        u[n+1] = u[n] - dVdx(u[n])*dt + sigma*sqrt(dt)*randn(rng);
        
        if mod(n,nDt)==0 
            y[round(Int,n/nDt)+1] = H*u[n+1] + sqrt(Gamma)*randn(rng);
        end
    end

    plotFigures = true;
    if plotFigures
        skip = round(Int, nDt/200);
        uPlot = u[1:skip:end];
        tU = range(0,stop=T,length=length(uPlot));
        tY = range(0,stop=T,length=nobs);
        
        thisPlot = plot(tU, uPlot, tY, y,"o")
        xlabel("t", fontsize=14)
        ylabel("u(t)", fontsize=14)
        gca().set_xlim(0,T)
        
        show(thisPlot)
        savefig("pathAndObs2.eps")
        
    end
    return u[1:nDt:end], y;
end
    


function generatePathAndObservations_OU(rng)
    
    #Dynamics for path u: linear mapping with additive noise u(n+1) = Psi(u_n) = Au_n + stdOU*N(0,1),
    # with A = exp(-tau) and stdOU
   
    stdOU = sigma*sqrt((1-exp(-2*tau))/2);
    y     = zeros(nobs);u = zeros(nobs);
    
    u[1] = u0; 
    y[1] = H*u[1]+ sqrt(Gamma)*randn(rng)
    
    for n=1:nobs-1
        u[n+1]  = u[n]*exp(-tau)+ stdOU*randn(rng);
        y[n+1]  = H*u[n+1] + sqrt(Gamma)*randn(rng);
    end 
    return u, y;
end

function computeRefSol_OU(y)
    #Assuming here that the following initial condition hold
    m = zeros(nobs); c = zeros(nobs);
    m[1] = u0; c[1] = Gamma;

    #Dynamics for path u: see generatPathAndObservations_OU
    A = exp(-tau); varOU = sigma^2*(1-exp(-2*tau))/2;
    
    for n=2:nobs
        # Prediction mean and covariance (assuming 1D setting)
        m[n] = A*m[n-1];
        c[n] = A*c[n-1]*A+varOU;
        
        # update mean and covariance
        K = c[n]*H/(Gamma+ H*c[n]*H);
        m[n] = (1-K*H)*m[n]+ K*y[n];
        c[n] = (1-K*H)*c[n];
    end
        
    return m,c
end


function computePseudoRefSol_DW(y, nobs=11)
    # We set nobs=21 by default (locally in this function) for reproducibility,
    # simply to ensure that the random seed is at the same location after computing
    # the synthetic reference solution regardless of whether T=10 or 20. 
    
    # spatial domain and resolution Nx, temporal resolution Nt.
    Nx = 100_000; Nt=1000;
    xLeft=-5; xRight=5;
    x=range(xLeft,stop=xRight,length=Nx+1);
    
    dx = x[2]-x[1];
    dt = tau/Nt;
    m = zeros(nobs); c = zeros(nobs);
    m[1] = u0;
    c[1] = Gamma;
    
    rho = exp.(-(x.-m[1]).^2/(2*c[1]));
    rho = rho/trapezoidal(rho,dx);
    # display( plot(x,rho))
   
    halfNx = round(Int, Nx/2);
    
    for n=2:nobs
        
	rho  = FP_pushforward(x,rho,Nt,Nx);
	rho  = rho/trapezoidal(rho,dx);
	
	m[n]   = trapezoidal(x.*rho,dx); #prediction mean temporary stored in update mean variable
	c[n]   = trapezoidal(((x.-m[n]).^2).*rho,dx); #prediction covariance temp stored in update cov
	K      = c[n]*H/(H*c[n]*H + Gamma); #assuming scalar H here
	xHat   = (x.-K*y[n])/abs(1-K*H);
        rhoV   = abs(1-K*H)\Spline1D([xHat[1]; x; xHat[Nx+1]],[0; rho; 0],k=1)(xHat)
	
	rhoEta = exp.(-(x/K).^2/(2*Gamma))/(K*sqrt(2*pi*Gamma));
	rhoTmp = conv(rhoV,rhoEta);
	#length(rhoTmp) = 2*(Nx+1)-1 = 2Nx+1 # extract same size vector as rho, ie length Nx+1 central part
	rho    = rhoTmp[halfNx+1:halfNx+Nx+1];
	rho    = rho/trapezoidal(rho,dx);
        
	m[n] = trapezoidal(x.*rho,dx); #update mean
	c[n] = trapezoidal( ((x.-m[n]).^2).*rho,dx); #update cov
    end
    return m,c
end

function FP_pushforward(x, rho, Nt,Nx)

    dx    = x[2]-x[1];      # spatial step size
    dt    = tau/Nt;         # time step
    nstep = Nt;   # number of time steps

    # Time stepping scheme (I-dt/2*A)rho_new = (I+dt/2*A)rho_old, A tridiagonal
    Vprimx = dVdx(x);
    Vbisx  = d2Vd2x(x);
    
    # Sub-diagonal elements of A
    Am     = sigma^2/dx^2/2*ones(Nx) - Vprimx[2:Nx+1]/dx/2;
    Am[Nx] = Am[Nx] + Vprimx[Nx+1]/dx/2+sigma^2/dx^2/2;         # Homo. Neumann through ghostpoint
    # Diagonal elements of A
        
    Ac     =  Vbisx .- ones(Nx+1)*sigma^2/dx^2;
    # Super-diagonal elements of A
    Ap     =  Vprimx[1:Nx]/dx/2 + ones(Nx)*sigma^2/dx^2/2;
    Ap[1]  = Ap[1] - Vprimx[1]/dx/2+sigma^2/dx^2/2;          # Homo. Neumann through ghostpoint
    # Matrix multiplying known solution values, at time t

    Aexpl = sparse(Tridiagonal( (dt/2)*Am, ones(Nx+1)+(dt/2)*Ac, (dt/2)*Ap));
    Aimpl = Tridiagonal( -(dt/2)*Am, ones(Nx+1)-(dt/2)*Ac, -(dt/2)*Ap);
    
    Aexpl
    # Matrix multiplying unknown solution values, at time t+dt
    # LU-factorization of tri-diagonal matrix has no fill in
    L,U = luTridiagHak(-(dt/2)*Am, ones(Nx+1)-(dt/2)*Ac, -(dt/2)*Ap);
    #L,U = lu(Aimpl);

    # ----- Time stepping scheme ------------------------------------- #
    for n=1:nstep
        # Implicit time step, linear cost for tri-diagonal system
        rho = U\(L\(Aexpl*rho));
    end
    rho = rho./trapezoidal(rho,dx); 
    return rho
end


function trapezoidal(fx,dx) # For fx column vecor or matrix
    I = (sum(fx)-0.5*(fx[1]+fx[end]))*dx;	    
    return I
end


function luTridiagHak(a,b,c)
    # lu factorize matrix diag(a,b,c)
    #returning L = lower(l,ones) and U = upper(v,c)

    n = length(b);
    v = zeros(n);
    l = zeros(n-1);
    v[1] = b[1];
    
    for k=1:n-1
        l[k] = a[k]/v[k]
        v[k+1]= b[k+1]-l[k]c[k]
    end
    L = Bidiagonal(ones(n),l,:L);
    U = Bidiagonal(v,c,:U);
    return L,U;
end

function plotResults(enkfFile,mlenkfOldFile,mlenkfFile)

    close("all")
    enkf= load(enkfFile);
    mlenkf = load(mlenkfFile);
    mlenkfOld = load(mlenkfOldFile);

    tEnkf    = enkf["timeEnkf"];
    errMEnkf = enkf["errMEnkf"];
    errCEnkf = enkf["errCEnkf"];
    
    tML    = mlenkf["timeMLEnkf"];
    errMML = mlenkf["errMMLEnkf"];
    errCML = mlenkf["errCMLEnkf"];
    tMLOld    = mlenkfOld["timeMLEnkfOld"];
    errMMLOld = mlenkfOld["errMMLEnkfOld"];
    errCMLOld = mlenkfOld["errCMLEnkfOld"];

 figure(2)

f(t) =  t.^(-1. /2);
    loglog(tMLOld, errMMLOld, "k-*", tML[1:end], errMML[1:end], "k-x",  tEnkf[1:end], errMEnkf[1:end], "k-o")
    xlabel("Runtime [sec]");    ylabel("RMSE");
#legend("MLEnKF Old","MLEnKF","c2^(-1/2)","EnKF","c2^(-1/3)")
    savefig("loglogRatesRmse_Mean$(problemText)_T$(T).eps", bbox_inches="tight");
    
 # reference triangle for MLEnKF
    loglog([1, 10], [10. ^(-4+0.1+1/3), 10. ^(-4+0.1+1/3)],"k", [1, 1], [10. ^(-4+0.1+1/3), 10. ^(-4+1/3+1/2)], "k", [1, 10], [10. ^(-4+1/3+1/2), 10. ^(-4+0.1+1/3)],"k")
    text(1-0.3,10. ^(-4+1/3+1/5), "1", fontsize=16)
    text(10. ^(1/2-0.1),10. ^(-4 +0.1+1/3-0.1) , "2", fontsize=16)

   # reference triangle for EnKF
    loglog([5, 50], [10. ^(-3+0.1), 10. ^(-3+0.1-1/3)],"k", [50, 50], [10. ^(-3+0.1), 10. ^(-3+0.1-1/3)], "k", [5, 50], [10. ^(-3+0.1), 10. ^(-3+0.1)],"k")
    text(15,10. ^(-3+0.11), "3", fontsize=16)
    text(55,10. ^(-3+0.1-1/6) , "1", fontsize=16)
    figure(3)

    loglog(tMLOld, errCMLOld, "k-*", tML[1:end], errCML[1:end], "k-x", tEnkf[1:end], errCEnkf[1:end], "k-o")
    xlabel("Runtime [sec]");    ylabel("RMSE");
    savefig("loglogRatesRmse_Cov$(problemText)_T$(T).eps", bbox_inches="tight");
   # legend("MLEnKF Old","MLEnKF","c2^(-1/2)","EnKF","c2^(-1/3)")

# reference triangle for MLEnKF
    loglog([1, 10], [10. ^(-4+1/3-1/2), 10. ^(-4+1/3-1/2)],"k", [1, 1], [10. ^(-4+1/3-1/2), 10. ^(-4+1/3)], "k", [1, 10], [10. ^(-4+1/3), 10. ^(-4+1/3-1/2)],"k")
    text(1-0.3,10. ^(-4+1/3-1/2+1/5), "1", fontsize=16)
    text(10. ^(1/2-0.1),10. ^(-4 +1/3-1/2-0.1) , "2", fontsize=16)

 # reference triangle for EnKF
    loglog([5, 50], [10. ^(-3-0.5), 10. ^(-3-0.5-1/3)],"k", [50, 50], [10. ^(-3-0.5), 10. ^(-3-0.5-1/3)], "k", [5, 50], [10. ^(-3-0.5), 10. ^(-3-0.5)],"k")
    text(15,10. ^(-3-0.5+0.01), "3", fontsize=16)
    text(55,10. ^(-3-0.5-1/6) , "1", fontsize=16)
    show()


end
