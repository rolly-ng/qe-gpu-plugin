#include <stdio.h>
#define _USE_CUDA_ 1

__global__ void qvan_kernel( double dqi, double *qmod, double *qrad, double *ylmk0,
                        double sig, double *qg, int qg_stride, int ngy) {

      double qm, work;
      double px, ux, vx, wx, uvx, pwx;
      int i0, i1, i2, i3;
      double sixth = 1.0/6.0;
      int ig = threadIdx.x + blockIdx.x * blockDim.x;
      if (ig < ngy) {
        qm = qmod[ig] * dqi;
        px = qm - int(qm);
        ux = 1.0 - px;
        vx = 2.0 - px;
        wx = 3.0 - px;
        // Not adding 1 here since it's an array index
        i0 = int(qm);
        i1 = i0 + 1;
        i2 = i0 + 2;
        i3 = i0 + 3;
        uvx = ux * vx * sixth;
        pwx = px * wx * 0.5;
        work = qrad [i0] * uvx * wx + 
               qrad [i1] * pwx * vx - 
               qrad [i2] * pwx * ux + 
               qrad [i3] * px * uvx;
  
        qg[qg_stride*ig] = qg[qg_stride*ig ] + sig * ylmk0[ig] * work;
      }

} 

extern int qvan2_cuda( int ngy, int ih, int jh, 
                            int np, double *qmod, double *qg, double *ylmk0, 
                            int ylmk0_s1, int nlx,  
                            double dq, double *qrad, int qrad_s1, int qrad_s2,
                            int qrad_s3, int *indv, int indv_s1,
                            int *nhtolm, int nhtolm_s1,
                            int nbetam, int *lpx, int lpx_s1,
                            int *lpl, int lpl_s1, int lpl_s2,
                            double *ap, int ap_s1, int ap_s2, cudaStream_t st) {

 /*  
     Input variables
 */ 
  /* ngy   :   number of G vectors to compute
     ih, jh:   first and second index of Q
     np    :   index of pseudopotentials
  */

  /* lots of array dimensions */
   int qg_s1 = 2;
  //adjust array indeces to begin with 0
   np = np - 1;
   ih = ih - 1;
   jh = jh - 1;
   //double *qmod, *ylmk0;

  /* ylmk0 :  spherical harmonics
     qmod  :  moduli of the q+g vectors
    
     output: the fourier transform of interest
  */
   //double *qg;

   //int *indv, *nhtolm, nbetam
   
   double sig;
  // the nonzero real or imaginary part of (-i)^L 
   double sixth = 1.0/6.0;
   int nb, mb, ijv, ivl, jvl, ig, lp, l, lm, i0, i1, i2, i3, ind;
  // nb,mb  : atomic index corresponding to ih,jh
  // ijv    : combined index (nb,mb)
  // ivl,jvl: combined LM index corresponding to ih,jh
  // ig     : counter on g vectors
  // lp     : combined LM index
  // l-1    is the angular momentum L
  // lm     : all possible LM's compatible with ih,jh
  // i0-i3  : counters for interpolation table
  // ind    : ind=1 if the results is real (l even), ind=2 if complex (l odd)
  //
  double dqi, qm, px, ux, vx, wx, uvx, pwx, work, qm1;
  // 1 divided dq
  // qmod/dq
  // measures for interpolation table
  // auxiliary variables for intepolation
  // auxiliary variables
  //
  //     compute the indices which correspond to ih,jh
  //
  dqi = 1.0/dq;
  nb = indv[ih + indv_s1*np ]; 
  mb = indv[jh + indv_s1*np ]; 
  if (nb > mb)
     ijv = nb * (nb - 1) / 2 + mb - 1;
  else
     ijv = mb * (mb - 1) / 2 + nb - 1;
  ivl = nhtolm[ih + nhtolm_s1*np ] - 1;
  jvl = nhtolm[jh + nhtolm_s1*np ] - 1;
  if (nb > nbetam || mb > nbetam) {
     fprintf(stderr, "  In qvan2, wrong dimensions (1) %d\n", max(nb,mb));
     exit(EXIT_FAILURE);
  }
  if (ivl > nlx || jvl > nlx) {
     fprintf(stderr, "  In qvan2, wrong dimensions (2) %d\n", max(ivl, jvl));
     exit(EXIT_FAILURE);
  }
#if _USE_CUDA_
  cudaMemsetAsync(qg, 0, sizeof(double)*ngy*2, st);
#else
  for (int q=0;q<2*ngy;q++) qg[q] = 0.0;
#endif
  cudaError_t err = cudaGetLastError();
  if (err) printf("qvan memset error number %d: %s\n", err, cudaGetErrorString(err));
  for (lm=0;lm<lpx[ivl + lpx_s1*jvl];lm++) {
    lp = lpl[ivl + lpl_s1*(jvl + lpl_s2*lm) ];
    if (lp == 1) {
       l = 0;
       sig = 1.0;
       ind = 0;
    } else if ( lp <= 4) {
       l = 1;
       sig =-1.0;
       ind = 1;
    } else if ( lp <= 9 ) {
       l = 2;
       sig =-1.0;
       ind = 0;
    } else if ( lp <= 16 ) {
       l = 3;
       sig = 1.0;
       ind = 1;
    } else if ( lp <= 25 ) {
       l = 4;
       sig = 1.0;
       ind = 0;
    } else if ( lp <= 36 ) {
       l = 5;
       sig =-1.0;
       ind = 1;
    } else {
       l = 6;
       sig =-1.0;
       ind = 0;
    }
    //Note: To avoid major changes to the comparisons above, we're leaving lp alone
    //    and subtracting 1 here
    sig = sig * ap[lp-1 + ap_s1*(ivl + ap_s2*jvl) ];
  
    qm1 = -1.0; // any number smaller than qmod[1]
#if _USE_CUDA_
    qvan_kernel<<<(ngy+127)/128,128,0,st>>>(dqi, qmod, qrad + (qrad_s1*(ijv + qrad_s2*(l + qrad_s3*np))), 
                      ylmk0+(lp-1)*ylmk0_s1, sig, qg + ind, 2, ngy); 
    cudaError_t err = cudaGetLastError();
    if (err) printf("qvan_kernel error number %d: %s\n", err, cudaGetErrorString(err));
#else
    #pragma omp parallel for default(shared), private(qm,px,ux,vx,wx,i0,i1,i2,i3,uvx,pwx,work)
    for (ig = 0; ig < ngy; ig++ ) {

        //
        // calculate quantites depending on the module of G only when needed
        //

#if ! defined __OPENMP
        if ( abs(qmod[ig] - qm1) > 1.0) {
#endif
          qm = qmod[ig] * dqi;
          px = qm - int(qm);
          ux = 1.0 - px;
          vx = 2.0 - px;
          wx = 3.0 - px;
          // Not adding 1 here since it's an array index
          i0 = int(qm);
          i1 = i0 + 1;
          i2 = i0 + 2;
          i3 = i0 + 3;
          uvx = ux * vx * sixth;
          pwx = px * wx * 0.5;
          work = qrad [i0+ qrad_s1*(ijv + qrad_s2*(l + qrad_s3*np))] * uvx * wx + 
                 qrad [i1+ qrad_s1*(ijv + qrad_s2*(l + qrad_s3*np))] * pwx * vx - 
                 qrad [i2+ qrad_s1*(ijv + qrad_s2*(l + qrad_s3*np))] * pwx * ux + 
                 qrad [i3+ qrad_s1*(ijv + qrad_s2*(l + qrad_s3*np))] * px * uvx;

#if ! defined __OPENMP
          qm1 = qmod[ig];
        }
#endif
      qg[ind + qg_s1*ig] = qg[ind + qg_s1*ig ] + sig * ylmk0[ig + ylmk0_s1*(lp-1) ] * work;
//      if (ig<2) {
//         printf("ig = %d. lm = %d, lp = %d\n", ig, lm, lp);
//         printf("   i3 = %d\n", i3);
//         printf("   qg[ind+2*ig] = %e\n", qg[ind+2*ig]);
//         printf("   qrad[i0,ijv,l,np] = %e\n", qrad [i3+ qrad_s1*(ijv + qrad_s2*(l + qrad_s3*np))]);
//         printf("   work = %e\n", work);
//         printf("   pwx = %e\n", pwx);
//      }

    }
#endif
  }
 
  return 1;
}