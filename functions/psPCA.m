% PSPCA Probabilistic Sparse Principal Component Analysis (for group analysis)
%       Finds sparse components describing the input data under a
%       homoscedastic noise assumption. The moments of the underlying
%       probability distributions are approximated by variational bayesian
%       inference. 
%
% INPUTS:
% "V" denotes number of voxels, "T" denotes number of time points, 
% "D" denotes number of components, "B" denotes number of subjects.
%
%   X:       A matrix of size V x T x B. Containing the observed data. 
%   D:       Number of components to look for
%   varargin:   Passing optional input arguments
%      'opts'           A structure with field names matching the variable
%                       input argument name. Note if an option is specified
%                       both in "opts" and in varargin, the value in "opts"
%                       will be used.
%      'conv_crit'      Convergence criteria, the algorithm stops if the
%                       relative change in lowerbound is below this value
%                       (default 1e-9). 
%      'maxiter'        Maximum number of iteration, stops here if
%                       convergence is not achieved (default 200).
%      'noise_process'  Model subject specific homoscedastic noise
%                       (default: true) 
%      'sparse_prior'   Model an elementwise sparsity pattern on A
%                       (probabilistic PCA is achieved if false) 
%                       (default: true)
%      'ard_prior'      Model automatic relevance determination (ARD) for
%                       the components (default: true).
%      'fixed_sparse'   Number of iterations before modeling sparsity
%                       pattern on A (default: 25). 
%      'fixed_ard'      Number of iterations before modeling component ARD
%                       (default: 30). 
%      'fixed_noise'    Number of iterations before modeling subject
%                       specific heteroscedastic noise (over voxels)
%                       (default: 35). 
%      'mean_process'   Model a subject specific mean value (A*S+mean =
%                       data) (default: false). 
%      'runGPU'         Run the model on graphics processing units (Only a
%                       single card is supported) (default: false).
%      'iter_disp'      How many iterations between console output
%                       (default: 1)
%      'beta'           Hyper-parameter for the mean (default: 1e-6).
%      'alpha_a'        Hyper-parameter for the sparsity pattern on A
%                       (default: 1e-6). 
%      'alpha_b'        Hyper-parameter for the sparsity pattern on A
%                       (default: 1e-6*scale/V).
%      'gamma_a'        Hyper-parameter for the ARD process (default: 1e-6).
%      'gamma_b'        Hyper-parameter for the ARD process (default: 1e-6*scale/(B*V)).
%      'tau_a'          Hyper-parameter for the subject specific noise
%                       precision (default: 1e-6). 
%      'tau_b'          Hyper-parameter for the subject specific noise
%                       precision (default: 1e-6*scale/V).
%      'rngSEED'        Specify a random seed for reproducability ([] means no seed is specified)
%
% OUTPUTS:
%   'first_moments':    First moment of the distributions.
%       'A'         A matrix V x D with the estimated (shared) mixing matrix
%       'S'         A matrix D x T x B with the estimated sources
%       'mu'        A matrix V x 1 x B with the mean of each subject. If a
%                   scalar (zero) is returned, then the mean was not modeled.
%       'alpha'     A matrix V x D with the estimated precision on the
%                   elements of A (i.e. the sparsity pattern)..
%       'gamma'     A vector D x 1 with the estimated ARD precisions.
%   'other_moments':    Other moments and parameters of the distributions.
%       'Sigma_A'   A matrix D x D x V with the covariance of A for each
%                   voxel (Sigma_A is voxels specific due to the sparsity
%                   pattern "alpha" on A) .
%       'Sigma_S'   A matrix D x D x B with the covariance of S for each
%                   subject.
%       'Sigma_mu'  A matrix V x 1 x B with the covariance of mu for each
%                   subject, off-diagonal elements are zero. Note if a
%                   scalar (zero) is returned, then the mean was not
%                   modeled.
%       'a_tau'     A scalar with the estimated first distributional
%                   parameter of tau (same for each subject).
%       'b_tau'     A matrix V x 1 x B with the estimated second
%                   distributional parameter of tau.
%       'a_alpha'   A scalar with the estimated first distributional
%                   parameter of alpha.
%       'b_alpha'   A matrix V x D with the estimated second distributional
%                   parameter of alpha. 
%       'a_gamma'   A scalar with the estimated first distributional
%                   parameter of gamma.
%       'b_gamma'   A matrix D x 1 with the estimated second
%                   distributional parameter of gamma.
%   'priors':       The initial hyper parameters of alpha, gamma, tau and mu.
%   'elbo':         The evidence lowerbound at each iteration.
%
%% References
% The Probabilistic Sparse PCA model (psPCA) was proposed by [1], the
% algorithm implemented here puts an ARD on the rows of S, to help pruning
% components in high dimensional settings. The model further extends psPCA
% to multi-subject data as described in [2,3]
%
%   *NOTE* Article [3] is currently under review. If you have any questions
%   contact the e-mail listed below. 
%
% [1] Guan, Y., & Dy, J. G. (2009). "Sparse Probabilistic Principal
%     Component Analysis", in AISTATS (pp. 185-192). 
% [2] Hinrich, J. L., Nielsen, S. F. V., Madsen, K. H., & Morup, M. (2016,
%     June). Variational group-PCA for intrinsic dimensionality
%     determination in fMRI data. In Pattern Recognition in Neuroimaging
%     (PRNI), 2016 International Workshop on (pp. 1-4). IEEE.   
% [3] Hinrich, J. L. et al. "Scalable Group Level Probabilistic Sparse 
%     Factor Analysis", in 2017 IEEE International Conference on Acoustics, 
%     Speech, and Signal Processing, ICASSP�17 (IN REVIEW). 2017, IEEE.
%
% Copyright (C) 2016 Technical University of Denmark - All Rights Reserved
% You may use, distribute and modify this code under the
% terms of the Probabilistic Latent Variable Modeling Toolbox for Multisubject Data license.
% 
% You should have received a copy of the license with this file. If not,
% please write to: jesper dot hinrich at gmail dot com, or visit : 
% https://brainconnectivity.compute.dtu.dk/ (under software)

function [first_moments,other_moments,priors,elbo] = psPCA(X,D,varargin)
disp('--- Running Probabilistic Sparse Principal Component Analysis ---')

[V,T,B] = size(X);
sumXsq = squeeze(sum(X.^2,1)); if B == 1, sumXsq = sumXsq'; end
scale = sum(sumXsq(:))/numel(X);

%% Get parameters
if nargin < 2
    D = T-1;
end
% Parse arguments and check if parameter/value pairs are valid 
paramNames = {'conv_crit','maxiter','noise_process','sparse_prior','ard_prior',...
              'mean_process','runGPU','iter_disp','beta','alpha_a','alpha_b',...
              'gamma_a','gamma_b','tau_a','tau_b','rngSEED','fixed_sparse',...
              'fixed_ard','fixed_noise','debug_mode','opts'};
defaults = {1e-9, 200, true , true , true, false, false, 1,...
            1e-6,1e-6,1e-6*scale/V,1e-6,1e-6*scale/(B*V),1e-6,1e-6*scale/V...
            [],25,30,35,false,[]};
    
[conv_crit, maxiter, model_tau, model_alpha, model_gamma,...
    model_mu, runGPU, iter_disp, beta0, alpha_a0, alpha_b0,...
    gamma_a0,gamma_b0,tau_a0,tau_b0,rngSEED,iter_alpha_fixed,...
    iter_gamma_fixed, iter_tau_fixed,opts]...
    = internal.stats.parseArgs(paramNames, defaults, varargin{:});
%Supporting passing a struct "opts" with optional parameters. In order to
%allow simultaneous an "opts" structure and variable input arguments(varargin) 
% the default values need to be whatever they became from the above line.
% Note that if an option is specified both in "opts" and in varargin, the
% value in "opts" will be used.
if ~isempty(opts)
    conv_crit = abs(mgetopt(opts,'conv_crit',1e-9));
    maxiter = mgetopt(opts,'maxiter',200);

    model_tau = mgetopt(opts,'noise_process',true);
    model_alpha = mgetopt(opts,'sparse_prior',true);
    model_gamma = mgetopt(opts,'ard_prior',true);
    model_mu = mgetopt(opts,'mean_process',false);
    runGPU = mgetopt(opts,'runGPU',false);
    iter_disp = mgetopt(opts,'iter_disp',1);

    %Hyper-parameters
    beta0    = mgetopt(opts,'beta',1e-6);
    alpha_a0 = mgetopt(opts,'alpha_a',1e-6);
    alpha_b0 = mgetopt(opts,'alpha_b',alpha_a0*scale/V);
    gamma_a0 = mgetopt(opts,'gamma_a',1e-6);
    gamma_b0 = mgetopt(opts,'gamma_b',gamma_a0*scale/(B*V));
    tau_a0 = mgetopt(opts,'tau_a',1e-6);
    tau_b0 = mgetopt(opts,'tau_b',tau_a0*scale/V);
    
    rngSEED = mgetopt(opts,'rngSEED',[]);
    db_flag = mgetopt(opts,'debug_mode',true);
    
    iter_alpha_fixed = mgetopt(opts,'fixed_sparse',25);
    iter_gamma_fixed = mgetopt(opts,'fixed_ard',iter_alpha_fixed+5);
    iter_tau_fixed = mgetopt(opts,'fixed_noise',iter_gamma_fixed+5);
end

if ~isempty(rngSEED)
    rng(rngSEED);
end

%% Initialize
%Transfer data to GPU if the calculations should be done there
if runGPU
    X = gpuArray(X);
end

EA = randn(V,D,'like',X);
ES = nan(D,T,B,'like',EA);
for b = 1:B
    ES(:,:,b) = EA\X(:,:,b);
end
Sigma_S = repmat(T*eye(D,'like',EA),1,1,B);
Sigma_A = repmat(eye(D,'like',EA),1,1,V);

if model_mu
    Emu = mean(X,2);
else
    Emu=zeros(V,1,B,'like',EA);
end
Sigma_mu = ones(V,1,B,'like',EA);

% <tau>
a_tau = tau_a0;%+T*V/2;
b_tau = tau_b0*ones(1,1,B,'like',EA)*scale;
Etau = a_tau./b_tau;
% <alpha>
a_alpha = alpha_a0;%+1/2;
b_alpha = alpha_b0*ones(V,D,'like',EA);
Ealpha = a_alpha./b_alpha;
%ARD prior on rows of Z
a_gamma = gamma_a0;%+T*B/2;
b_gamma = gamma_b0*ones(D,1,'like',EA);
Egamma = a_gamma./b_gamma;
%Eln_gamma = psi(a_gamma)-log(b_gamma);

%%
elbo = zeros(1,maxiter,'like',EA);
iter = 0;

Iq = eye(D,'like',EA);

if runGPU % Determine memory usage on GPU after initialization
    gpu = gpuDevice();
    fprintf('Mem avail. after allocate: %f Gb \n',gpu.AvailableMemory*(9.31322574615e-10));
end

lbnorm = 2*conv_crit;

dheader = sprintf('%16s | %12s | %12s | %12s |','Iteration','Lowerbound','Delta LBf.',' Time(s)  ');
dline = sprintf('-----------------+--------------+--------------+--------------+');
fprintf('%s\n%s\n',dheader,dline)
t0=tic; t1=tic;
while lbnorm > conv_crit && iter < maxiter...
        || (model_tau && iter <= iter_tau_fixed)...
        || (model_alpha && iter <= iter_alpha_fixed)...
        || (model_gamma && iter <= iter_gamma_fixed)
    iter = iter + 1;
    
    %% Update S
    EAtA = symmetrizing(EA'*EA,db_flag)+sum(Sigma_A,3); %<A^T A>
    Sigma_S = my_pagefun(@inv,my_pagefun(@plus,bsxfun(@times,EAtA,Etau),diag(Egamma)) );
    Sigma_S = (Sigma_S+permute(Sigma_S,[2,1,3]))/2;

    ES = bsxfun(@times,my_pagefun(@mtimes,Sigma_S,my_pagefun(@mtimes,EA',bsxfun(@minus,X,Emu))),Etau);
    ESSt = my_pagefun(@mtimes,ES,permute(ES,[2,1,3]))+T*Sigma_S;

    %% Update mu
    if model_mu
        Sigma_mu = repmat((1./(beta0 + T*Etau)),V,1,1);
        Emu = bsxfun(@times,Etau,Sigma_mu).*(sum(X,2) - sum(my_pagefun(@mtimes, EA, ES),2));
    end
    
    %% Update A
    ESStau = sum(my_pagefun(@times,ESSt,Etau),3);
    Sigma_A = my_pagefun(@plus,bsxfun(@times,ESStau,reshape(1./Ealpha',1,D,V)),Iq);
    Sigma_A = my_pagefun(@inv,Sigma_A);
    Sigma_A = bsxfun(@times,Sigma_A,reshape(1./Ealpha',D,1,V));

    b_mu_A_sum = sum(bsxfun(@times,my_pagefun(@mtimes,ES,permute(bsxfun(@minus,X,Emu),[2,1,3])),Etau),3);
    EA = reshape(my_pagefun(@mtimes,Sigma_A,reshape(b_mu_A_sum,D,1,V)),D,V)';
    EAtA = symmetrizing(EA'*EA,db_flag)+sum(Sigma_A,3); 

    %% Update Alpha 
    if model_alpha && iter > iter_alpha_fixed
        a_alpha = alpha_a0+0.5;
        b_alpha = alpha_b0+0.5*(EA.^2+Sigma_A(bsxfun(@plus,(1:D+1:D^2)',(0:V-1)*D^2))');
        Ealpha = a_alpha./b_alpha;
    end
    
    %% Update Gamma
    if model_gamma && iter > iter_gamma_fixed
       a_gamma = gamma_a0+T*B/2;
       b_gamma = gamma_b0+0.5*diag(sum(ESSt,3));
    end
    Egamma = a_gamma./b_gamma;

 
    %% Update Tau
    if iter >1
        err_sse_old = err_sse;  %#ok<NASGU>
    end
    %Reconstruction error (sum of squared error)
    err_sse = sum(sum(X.^2))+T*(sum(Sigma_mu)+sum(Emu.^2))... 
        + sum(sum(my_pagefun(@times, EAtA, ESSt),1),2)... %Trace(<A^T A> * <St St^T>)
    	+ 2*my_pagefun(@mtimes,permute(Emu,[2,1,3]),my_pagefun(@mtimes,EA,sum(ES,2))-sum(X,2))... % 
    	- 2 * sum(sum(my_pagefun(@times, EA', my_pagefun(@mtimes, ES, permute(X,[2,1,3]))),1),2);
    
    if model_tau && iter > iter_tau_fixed
        a_tau = tau_a0 + T*V/2; %subject specific
        b_tau = tau_b0 + 0.5*err_sse;
        Etau = a_tau./b_tau;
    end
    
    %Now check convergence every "step" iteration.
    elbo(iter) = calculate_ELBO(err_sse,Sigma_S, ES,a_tau, b_tau, tau_a0,...
                tau_b0, Sigma_mu,Emu, beta0, Sigma_A, EA, X, a_alpha,b_alpha,...
                alpha_a0,alpha_b0,a_gamma,b_gamma,gamma_a0,gamma_b0);
        
    if iter > 1
        lbnorm = (elbo(iter)-elbo(iter-1))/abs(elbo(iter));

        if mod(iter,iter_disp) == 0
            delta_t = toc(t1);
            if mod(iter,iter_disp*10) == 0
                fprintf('%s\n%s\n%s\n',dline,dheader,dline)
            end
            fprintf('%6.0f of %6.0f | %12.4e | %12.4e | %12.4f |\n',iter,maxiter,elbo(iter),lbnorm,delta_t);

            if delta_t < 1
                iter_disp = iter_disp*2;
            end
            t1=tic;
        end

        %Check for convergence issues
        [iter_alpha_fixed,iter_gamma_fixed,iter_tau_fixed] = ...
        asses_convergence(lbnorm,conv_crit,iter,...
                        model_alpha,model_gamma,model_tau,...
                        iter_alpha_fixed,iter_gamma_fixed,iter_tau_fixed);
    end        

    
end

delta_t = toc(t1);
fprintf('%6.0f of %6.0f | %12.4e | %12.4e | %12.4f |\n',iter,maxiter,elbo(iter),lbnorm,delta_t);
if runGPU
    gpu = gpuDevice();
    fprintf('(%f Gb), time: %f seconds\n',gpu.AvailableMemory*(9.31322574615e-10),toc(t0));
end

if model_gamma
    [~,idx] = sort(Egamma);
else
    [~,idx] = sort(mean(Ealpha));
end
%Save to output
first_moments.A = gather(EA(:,idx));
first_moments.S = gather(ES(idx,:,:));
first_moments.mu = gather(Emu);
first_moments.alpha = gather(Ealpha(:,idx));
first_moments.tau = gather(Etau);
first_moments.gamma = gather(Egamma(idx));

other_moments.Sigma_A = gather(Sigma_A(idx,idx,:));
other_moments.Sigma_S = gather(Sigma_S(idx,idx,:));
other_moments.Sigma_mu = gather(Sigma_mu);
other_moments.a_tau = gather(a_tau);
other_moments.b_tau = gather(b_tau);
if model_alpha
    other_moments.a_alpha = gather(a_alpha);
    other_moments.b_alpha = gather(b_alpha(:,idx));
end
if model_gamma
    other_moments.a_gamma = gather(a_gamma);
    other_moments.b_gamma = gather(b_gamma(idx));
end

priors.alpha_a0 = alpha_a0;
priors.alpha_b0 = alpha_b0;
priors.gamma_a0 = gamma_a0;
priors.gamma_b0 = gamma_b0;
priors.tau_a0 = tau_a0;
priors.tau_b0 = tau_b0;
priors.beta0 = beta0;

elbo = gather(elbo);

end

function lb = calculate_ELBO(err_sse,Sigma_S, ES, a_tau, b_tau, a_tau0, b_tau0,...
    Sigma_mu, Emu, beta, Sigma_A, EA, X, alpha_a,alpha_b,alpha_a0,alpha_b0,...
    gamma_a,gamma_b,gamma_a0,gamma_b0)

[V, T, B] = size(X);
[~,D] = size(EA);

%% Gamma
Egamma = gamma_a./gamma_b;
Eln_gamma = psi(gamma_a)-log(gamma_b);
ent_gamma = sum(gamma_entropy(gamma_a,gamma_b));
logP_gamma = -D*gammaln(gamma_a0)+D*gamma_a0*log(gamma_b0)...
            +sum((gamma_a0-1).*Eln_gamma)-sum(gamma_b0.*Egamma);

%% S
ent_S = 0;
for b = 1:B
   ent_S = ent_S+T*gaussian_entropy(Sigma_S(:,:,b),D,0);
end
tr_S_S = sum(Sigma_S(bsxfun(@plus,(1:D+1:D*D)',(0:B-1)*D*D)),2);
logP_S = -0.5*B*T*D*log(2*pi)+0.5*B*T*sum(Eln_gamma)...
        -0.5*sum((tr_S_S + sum(sum(ES.^2,2),3)).*Egamma) ;

%% tau
Etau = a_tau./b_tau;
Eln_tau = psi(a_tau)-log(b_tau);
ent_tau = sum(gamma_entropy(a_tau,b_tau));
logP_tau = -B*gammaln(a_tau0)+B*a_tau0*log(b_tau0) + (a_tau0-1)*...
       sum(Eln_tau) - b_tau0*sum(Etau);

%% mu
ent_mu = 0.5*sum(log(Sigma_mu(:))) + 0.5*B*V*(1+log(2*pi));
logP_mu = 0.5*B*V*(log(beta) - log(2*pi)) - 0.5*beta*(sum(sum(Sigma_mu)) + sum(sum(Emu.^2)));

%% alpha
Ealpha = alpha_a./alpha_b;
Eln_alpha = psi(alpha_a)-log(alpha_b);
ent_alpha = sum(sum(gamma_entropy(alpha_a,alpha_b)));
%logP_alpha = -sum(Eln_alpha(:));%Jeffrey
logP_alpha = V*D*(-gammaln(alpha_a0)+alpha_a0*log(alpha_b0))...
             +(alpha_a0-1)*sum(Eln_alpha(:))-alpha_b0*sum(Ealpha(:));

%% A 
% compute <A.^2> 
EAoA = EA.^2 + Sigma_A(bsxfun(@plus,(1:D+1:D^2)',(0:V-1)*D^2))';
logP_A = -0.5*V*D*log(2*pi)+0.5*sum(Eln_alpha(:))-0.5*sum(sum(EAoA.*Ealpha));

logdet_Sigma_A = 0;
Sigma_A = gather(Sigma_A);
for i=1:V
    logdet_Sigma_A=logdet_Sigma_A+2*sum(log(diag(chol(Sigma_A(:,:,i)))));
end
ent_A =  0.5*V*D*(1+log(2*pi))+0.5*logdet_Sigma_A;

%% x 
logP_X =  -0.5*T*V*B*log(2*pi)+0.5*T*V*sum(Eln_tau)- 0.5*sum(Etau.*err_sse,3);

lb = logP_X+logP_A+logP_S+logP_mu+logP_tau+logP_alpha+logP_gamma+...
            ent_A+ent_S+ent_mu+ent_tau+ent_alpha+ent_gamma;

end