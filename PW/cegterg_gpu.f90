! Copyright (C) 2001-2014 Quantum ESPRESSO Foundation
!
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
#if defined(__CUDA) && defined(__PHIGEMM)
#define dgemm UDGEMM  
#define zgemm UZGEMM  
#define DGEMM UDGEMM  
#define ZGEMM UZGEMM  
#if defined(__PHIGEMM_PROFILE)
#define _STRING_LINE_(s) #s
#define _STRING_LINE2_(s) _STRING_LINE_(s)
#define __LINESTR__ _STRING_LINE2_(__LINE__)
#define UDGEMM(TRANSA,TRANSB,M,N,K,ALPHA,A,LDA,B,LDB,BETA,C,LDC) phidgemm(TRANSA,TRANSB,M,N,K,ALPHA,A,LDA,B,LDB,BETA,C,LDC,__FILE__,__LINESTR__)
#define UZGEMM(TRANSA,TRANSB,M,N,K,ALPHA,A,LDA,B,LDB,BETA,C,LDC) phizgemm(TRANSA,TRANSB,M,N,K,ALPHA,A,LDA,B,LDB,BETA,C,LDC,__FILE__,__LINESTR__)
#else
#define UDGEMM phidgemm
#define UZGEMM phizgemm
#endif
#endif
!
#define ZERO ( 0.D0, 0.D0 )
#define ONE  ( 1.D0, 0.D0 )
!
!
!----------------------------------------------------------------------------
SUBROUTINE cegterg_gpu( npw, npwx, nvec, nvecx, npol, evc, ethr, &
                    uspp, e, btype, notcnv, lrot, dav_iter )
  !----------------------------------------------------------------------------
  !
  ! ... iterative solution of the eigenvalue problem:
  !
  ! ... ( H - e S ) * evc = 0
  !
  ! ... where H is an hermitean operator, e is a real scalar,
  ! ... S is an overlap matrix, evc is a complex vector
  !
  USE kinds,            ONLY : DP
  USE mp_bands ,        ONLY : intra_bgrp_comm
  USE mp,               ONLY : mp_sum
  !
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  USE iso_c_binding
  USE cuda_mem_alloc
#endif
  !
  IMPLICIT NONE
  !
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  INTEGER :: res
#endif
  INTEGER, INTENT(IN) :: npw, npwx, nvec, nvecx, npol
    ! dimension of the matrix to be diagonalized
    ! leading dimension of matrix evc, as declared in the calling pgm unit
    ! integer number of searched low-lying roots
    ! maximum dimension of the reduced basis set :
    !    (the basis set is refreshed when its dimension would exceed nvecx)
    ! umber of spin polarizations
  COMPLEX(DP), INTENT(INOUT) :: evc(npwx,npol,nvec)
    !  evc contains the  refined estimates of the eigenvectors  
  REAL(DP), INTENT(IN) :: ethr
    ! energy threshold for convergence :
    !   root improvement is stopped, when two consecutive estimates of the root
    !   differ by less than ethr.
  LOGICAL, INTENT(IN) :: uspp
    ! if .FALSE. : do not calculate S|psi>
  INTEGER, INTENT(IN) :: btype(nvec)
    ! band type ( 1 = occupied, 0 = empty )
  LOGICAL, INTENT(IN) :: lrot
    ! .TRUE. if the wfc have already been rotated
  REAL(DP), INTENT(OUT) :: e(nvec)
    ! contains the estimated roots.
  INTEGER, INTENT(OUT) :: dav_iter, notcnv
    ! integer number of iterations performed
    ! number of unconverged roots
  !
  ! ... LOCAL variables
  !
  INTEGER, PARAMETER :: maxter = 20
  ! maximum number of iterations
  !
  INTEGER :: kter, nbase, np, kdim, kdmx, n, m, nb1, nbn
    ! counter on iterations
    ! dimension of the reduced basis
    ! counter on the reduced basis vectors
    ! adapted npw and npwx
    ! do-loop counters
  INTEGER :: ierr
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
    COMPLEX(fp_kind), DIMENSION(:,:), POINTER :: hc(:,:), sc(:,:), vc(:,:)
#else
    COMPLEX(DP), ALLOCATABLE :: hc(:,:), sc(:,:), vc(:,:)
#endif
    ! Hamiltonian on the reduced basis
    ! S matrix on the reduced basis
    ! the eigenvectors of the Hamiltonian
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  COMPLEX(fp_kind), DIMENSION(:,:), POINTER :: psi(:,:,:), hpsi(:,:,:), spsi(:,:,:)
#else
  COMPLEX(DP), ALLOCATABLE :: psi(:,:,:), hpsi(:,:,:), spsi(:,:,:)
#endif
    ! work space, contains psi
    ! the product of H and psi
    ! the product of S and psi
  REAL(DP), ALLOCATABLE :: ew(:)
    ! eigenvalues of the reduced hamiltonian
  LOGICAL, ALLOCATABLE  :: conv(:)
    ! true if the root is converged
  REAL(DP) :: empty_ethr 
    ! threshold for empty bands
  !
  REAL(DP), EXTERNAL :: ddot
  !
  ! EXTERNAL  h_psi,    s_psi,    g_psi
    ! h_psi(npwx,npw,nvec,psi,hpsi)
    !     calculates H|psi>
    ! s_psi(npwx,npw,nvec,spsi)
    !     calculates S|psi> (if needed)
    !     Vectors psi,hpsi,spsi are dimensioned (npwx,npol,nvec)
    ! g_psi(npwx,npw,notcnv,psi,e)
    !    calculates (diag(h)-e)^-1 * psi, diagonal approx. to (h-e)^-1*psi
    !    the first nvec columns contain the trial eigenvectors
  !
  !
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  TYPE(C_PTR) :: cptr_psi, cptr_spsi, cptr_vc, cptr_hpsi, cptr_sc, cptr_hc
  INTEGER (C_SIZE_T), PARAMETER :: test_flag = 0
  INTEGER (C_SIZE_T) :: allocation_size
#endif
  !
#if defined(__CUDA_DEBUG)
  WRITE(*,*) "[CEGTERG] Enter"
#endif
  !
  CALL start_clock( 'cegterg' )
  !
  IF ( nvec > nvecx / 2 ) CALL errore( 'cegterg', 'nvecx is too small', 1 )
  !
  ! ... threshold for empty bands
  !
  empty_ethr = MAX( ( ethr * 5.D0 ), 1.D-5 )
  !
  IF ( npol == 1 ) THEN
     !
     kdim = npw
     kdmx = npwx
     !
  ELSE
     !
     kdim = npwx*npol
     kdmx = npwx*npol
     !
  END IF
  !
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  allocation_size = npol*npwx*nvecx*sizeof(fp_kind)*4
  res = cudaHostAlloc ( cptr_psi, allocation_size, test_flag )
  CALL c_f_pointer ( cptr_psi, psi, (/ npwx, npol, nvecx /) )
  res = cudaHostAlloc ( cptr_hpsi, allocation_size, test_flag )
  CALL c_f_pointer ( cptr_hpsi, hpsi, (/ npwx, npol, nvecx /) )
#else
  ALLOCATE(  psi( npwx, npol, nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( ' cegterg ',' cannot allocate psi ', ABS(ierr) )
  ALLOCATE( hpsi( npwx, npol, nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( ' cegterg ',' cannot allocate hpsi ', ABS(ierr) )
#endif
  !
  IF ( uspp )THEN
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
     res = cudaHostAlloc ( cptr_spsi, allocation_size, test_flag )
     CALL c_f_pointer ( cptr_spsi, spsi, (/ npwx, npol, nvecx /) )
#else
     ALLOCATE( spsi( npwx, npol, nvecx ), STAT=ierr )
     IF( ierr /= 0 ) &
        CALL errore( ' cegterg ',' cannot allocate spsi ', ABS(ierr) )
#endif
  END IF
  !
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  allocation_size = nvecx*nvecx*sizeof(fp_kind)*4
  res = cudaHostAlloc ( cptr_sc, allocation_size, test_flag )
  CALL c_f_pointer ( cptr_sc, sc, (/ nvecx, nvecx /) )
  res = cudaHostAlloc ( cptr_hc, allocation_size, test_flag )
  CALL c_f_pointer ( cptr_hc, hc, (/ nvecx, nvecx /) )
  res = cudaHostAlloc ( cptr_vc, allocation_size, test_flag )
  CALL c_f_pointer ( cptr_vc, vc, (/ nvecx, nvecx /) )
#else
  ALLOCATE( sc( nvecx, nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( ' cegterg ',' cannot allocate sc ', ABS(ierr) )
  ALLOCATE( hc( nvecx, nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( ' cegterg ',' cannot allocate hc ', ABS(ierr) )
  ALLOCATE( vc( nvecx, nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( ' cegterg ',' cannot allocate vc ', ABS(ierr) )
#endif
  ALLOCATE( ew( nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( ' cegterg ',' cannot allocate ew ', ABS(ierr) )
  ALLOCATE( conv( nvec ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( ' cegterg ',' cannot allocate conv ', ABS(ierr) )
  !
  notcnv = nvec
  nbase  = nvec
  conv   = .FALSE.
  !
  IF ( uspp ) spsi = ZERO
  !
  hpsi = ZERO
  psi  = ZERO
  psi(:,:,1:nvec) = evc(:,:,1:nvec)
  !
  ! ... hpsi contains h times the basis vectors
  !
  CALL h_psi( npwx, npw, nvec, psi, hpsi )
  !
  ! ... spsi contains s times the basis vectors
  !
  IF ( uspp ) CALL s_psi( npwx, npw, nvec, psi, spsi )
  !
  ! ... hc contains the projection of the hamiltonian onto the reduced 
  ! ... space vc contains the eigenvectors of hc
  !
  hc(:,:) = ZERO
  sc(:,:) = ZERO
  vc(:,:) = ZERO
  !
  CALL ZGEMM( 'C', 'N', nbase, nbase, kdim, ONE, &
              psi, kdmx, hpsi, kdmx, ZERO, hc, nvecx )
  !
  CALL mp_sum( hc( :, 1:nbase ), intra_bgrp_comm )
  !
  IF ( uspp ) THEN
     !
     CALL ZGEMM( 'C', 'N', nbase, nbase, kdim, ONE, &
                 psi, kdmx, spsi, kdmx, ZERO, sc, nvecx )
     !     
  ELSE
     !
     CALL ZGEMM( 'C', 'N', nbase, nbase, kdim, ONE, &
                 psi, kdmx, psi, kdmx, ZERO, sc, nvecx )
     !
  END IF
  !
  CALL mp_sum( sc( :, 1:nbase ), intra_bgrp_comm )
  !
  IF ( lrot ) THEN
     !
     DO n = 1, nbase
        !
        e(n) = REAL( hc(n,n) )
        !
        vc(n,n) = ONE
        !
     END DO
     !
  ELSE
     !
     ! ... diagonalize the reduced hamiltonian
     !
     CALL cdiaghg( nbase, nvec, hc, sc, nvecx, ew, vc )
     !
     e(1:nvec) = ew(1:nvec)
     !
  END IF
  !
  ! ... iterate
  !
  iterate: DO kter = 1, maxter
     !
     dav_iter = kter
     !
     CALL start_clock( 'cegterg:update' )
     !
     np = 0
     !
     DO n = 1, nvec
        !
        IF ( .NOT. conv(n) ) THEN
           !
           ! ... this root not yet converged ... 
           !
           np = np + 1
           !
           ! ... reorder eigenvectors so that coefficients for unconverged
           ! ... roots come first. This allows to use quick matrix-matrix 
           ! ... multiplications to set a new basis vector (see below)
           !
           IF ( np /= n ) vc(:,np) = vc(:,n)
           !
           ! ... for use in g_psi
           !
           ew(nbase+np) = e(n)
           !
        END IF
        !
     END DO
     !
     nb1 = nbase + 1
     !
     ! ... expand the basis set with new basis vectors ( H - e*S )|psi> ...
     !
     IF ( uspp ) THEN
        !
        
#if defined(__IMPROVED_GEMM)
        IF ( notcnv == 1 ) THEN
           !
           CALL ZGEMV( 'N', kdim, nbase, ONE, spsi, kdmx, vc, 1, ZERO, &
                     psi(1,1,nb1), 1 )
           !
        ELSE
           !
           CALL ZGEMM( 'N', 'N', kdim, notcnv, nbase, ONE, spsi, &
               kdmx, vc, nvecx, ZERO, psi(1,1,nb1), kdmx )

           !
        ENDIF
        !
#else
        ! ORIGINAL:
        CALL ZGEMM( 'N', 'N', kdim, notcnv, nbase, ONE, spsi, &
                    kdmx, vc, nvecx, ZERO, psi(1,1,nb1), kdmx )
#endif
        !     
     ELSE
        !
#if defined(__IMPROVED_GEMM)
        IF ( notcnv == 1 ) THEN
           !
           CALL ZGEMV( 'N', kdim, nbase, ONE, psi, kdmx, vc, 1, ZERO, &
                     psi(1,1,nb1), 1 )
           !
        ELSE
           !
           CALL ZGEMM( 'N', 'N', kdim, notcnv, nbase, ONE, psi, &
                  kdmx, vc, nvecx, ZERO, psi(1,1,nb1), kdmx )
           !
        ENDIF
        !
#else
        ! ORIGINAL:
        CALL ZGEMM( 'N', 'N', kdim, notcnv, nbase, ONE, psi, &
                  kdmx, vc, nvecx, ZERO, psi(1,1,nb1), kdmx )
#endif
        !
     END IF
     !
     DO np = 1, notcnv
        !
        psi(:,:,nbase+np) = - ew(nbase+np)*psi(:,:,nbase+np)
        !
     END DO
     !
#if defined(__IMPROVED_GEMM)
     IF ( notcnv == 1 ) THEN
        !
        CALL ZGEMV( 'N', kdim, nbase, ONE, hpsi, kdmx, vc, 1, ONE, &
             psi(1,1,nb1), 1 )
        !
     ELSE
        !
        CALL ZGEMM( 'N', 'N', kdim, notcnv, nbase, ONE, hpsi, &
                 kdmx, vc, nvecx, ONE, psi(1,1,nb1), kdmx )
        !
     ENDIF
     !
#else
     ! ORIGINAL:
     CALL ZGEMM( 'N', 'N', kdim, notcnv, nbase, ONE, hpsi, &
                 kdmx, vc, nvecx, ONE, psi(1,1,nb1), kdmx )
#endif
     !
     CALL stop_clock( 'cegterg:update' )
     !
     ! ... approximate inverse iteration
     !
     CALL g_psi( npwx, npw, notcnv, npol, psi(1,1,nb1), ew(nb1) )
     !
     ! ... "normalize" correction vectors psi(:,nb1:nbase+notcnv) in
     ! ... order to improve numerical stability of subspace diagonalization
     ! ... (cdiaghg) ew is used as work array :
     !
     ! ...         ew = <psi_i|psi_i>,  i = nbase + 1, nbase + notcnv
     !
     DO n = 1, notcnv
        !
        nbn = nbase + n
        !
        IF ( npol == 1 ) THEN
           !
           ew(n) = ddot( 2*npw, psi(1,1,nbn), 1, psi(1,1,nbn), 1 )
           !
        ELSE
           !
           ew(n) = ddot( 2*npw, psi(1,1,nbn), 1, psi(1,1,nbn), 1 ) + &
                   ddot( 2*npw, psi(1,2,nbn), 1, psi(1,2,nbn), 1 )
           !
        END IF
        !
     END DO
     !
     CALL mp_sum( ew( 1:notcnv ), intra_bgrp_comm )
     !
     DO n = 1, notcnv
        !
        psi(:,:,nbase+n) = psi(:,:,nbase+n) / SQRT( ew(n) )
        !
     END DO
     !
     ! ... here compute the hpsi and spsi of the new functions
     !
     !
     CALL h_psi( npwx, npw, notcnv, psi(1,1,nb1), hpsi(1,1,nb1) )
     !
     IF ( uspp ) &
        CALL s_psi( npwx, npw, notcnv, psi(1,1,nb1), spsi(1,1,nb1) )
     !
     ! ... update the reduced hamiltonian
     !
     CALL start_clock( 'cegterg:overlap' )
     !
#if defined(__IMPROVED_GEMM)
     IF ( notcnv == 1 ) THEN
        !
        CALL ZGEMV( 'C', kdim, nbase+notcnv, ONE, psi, kdmx, hpsi(1,1,nb1), 1, ZERO, &
                     hc(1,nb1), 1 )
        !
     ELSE
        !
        CALL ZGEMM( 'C', 'N', nbase+notcnv, notcnv, kdim, ONE, psi, &
                 kdmx, hpsi(1,1,nb1), kdmx, ZERO, hc(1,nb1), nvecx )
        !
     ENDIF
     !
#else
     ! ORIGINAL:
     CALL ZGEMM( 'C', 'N', nbase+notcnv, notcnv, kdim, ONE, psi, &
                 kdmx, hpsi(1,1,nb1), kdmx, ZERO, hc(1,nb1), nvecx )
#endif
     !
     CALL mp_sum( hc( :, nb1:nb1+notcnv-1 ), intra_bgrp_comm )
     !
     IF ( uspp ) THEN
        !
#if defined(__IMPROVED_GEMM)
        IF ( notcnv == 1 ) THEN
           !
           CALL ZGEMV( 'C', kdim, nbase+notcnv, ONE, psi, kdmx, spsi(1,1,nb1), 1, ZERO, &
                     sc(1,nb1), 1 )
           !
        ELSE
           !
           CALL ZGEMM( 'C', 'N', nbase+notcnv, notcnv, kdim, ONE, psi, &
               kdmx, spsi(1,1,nb1), kdmx, ZERO, sc(1,nb1), nvecx )
           !
        ENDIF
#else
        ! ORIGINAL:
        CALL ZGEMM( 'C', 'N', nbase+notcnv, notcnv, kdim, ONE, psi, &
                    kdmx, spsi(1,1,nb1), kdmx, ZERO, sc(1,nb1), nvecx )
#endif
        !     
     ELSE
        !
#if defined(__IMPROVED_GEMM)
        IF ( notcnv == 1 ) THEN
           !
           CALL ZGEMV( 'C', kdim, nbase+notcnv, ONE, psi, kdmx, psi(1,1,nb1), 1, ZERO, &
                     sc(1,nb1), 1 )
           !
        ELSE
           !
           CALL ZGEMM( 'C', 'N', nbase+notcnv, notcnv, kdim, ONE, psi, &
                  kdmx, psi(1,1,nb1), kdmx, ZERO, sc(1,nb1), nvecx )
          !
        ENDIF
        !
#else
        ! ORIGINAL:
        CALL ZGEMM( 'C', 'N', nbase+notcnv, notcnv, kdim, ONE, psi, &
                    kdmx, psi(1,1,nb1), kdmx, ZERO, sc(1,nb1), nvecx )
#endif
        !
     END IF
     !
     CALL mp_sum( sc( :, nb1:nb1+notcnv-1 ), intra_bgrp_comm )
     !
     CALL stop_clock( 'cegterg:overlap' )
     !
     nbase = nbase + notcnv
     !
     DO n = 1, nbase
        !
        ! ... the diagonal of hc and sc must be strictly real 
        !
        hc(n,n) = CMPLX( REAL( hc(n,n) ), 0.D0 ,kind=DP)
        sc(n,n) = CMPLX( REAL( sc(n,n) ), 0.D0 ,kind=DP)
        !
        DO m = n + 1, nbase
           !
           hc(m,n) = CONJG( hc(n,m) )
           sc(m,n) = CONJG( sc(n,m) )
           !
        END DO
        !
     END DO
     !
     ! ... diagonalize the reduced hamiltonian
     !
     CALL cdiaghg( nbase, nvec, hc, sc, nvecx, ew, vc )
     !
     ! ... test for convergence
     !
     WHERE( btype(1:nvec) == 1 )
        !
        conv(1:nvec) = ( ( ABS( ew(1:nvec) - e(1:nvec) ) < ethr ) )
        !
     ELSEWHERE
        !
        conv(1:nvec) = ( ( ABS( ew(1:nvec) - e(1:nvec) ) < empty_ethr ) )
        !
     END WHERE
     !
     notcnv = COUNT( .NOT. conv(:) )
     !
     e(1:nvec) = ew(1:nvec)
     !
     ! ... if overall convergence has been achieved, or the dimension of
     ! ... the reduced basis set is becoming too large, or in any case if
     ! ... we are at the last iteration refresh the basis set. i.e. replace
     ! ... the first nvec elements with the current estimate of the
     ! ... eigenvectors;  set the basis dimension to nvec.
     !
     IF ( notcnv == 0 .OR. &
          nbase+notcnv > nvecx .OR. dav_iter == maxter ) THEN
        !
        CALL start_clock( 'cegterg:last' )
        !
        CALL ZGEMM( 'N', 'N', kdim, nvec, nbase, ONE, &
                    psi, kdmx, vc, nvecx, ZERO, evc, kdmx )
        !
        IF ( notcnv == 0 ) THEN
           !
           ! ... all roots converged: return
           !
           CALL stop_clock( 'cegterg:last' )
           !
           EXIT iterate
           !
        ELSE IF ( dav_iter == maxter ) THEN
           !
           ! ... last iteration, some roots not converged: return
           !
           !!!WRITE( stdout, '(5X,"WARNING: ",I5, &
           !!!     &   " eigenvalues not converged")' ) notcnv
           !
           CALL stop_clock( 'cegterg:last' )
           !
           EXIT iterate
           !
        END IF
        !
        ! ... refresh psi, H*psi and S*psi
        !
        psi(:,:,1:nvec) = evc(:,:,1:nvec)
        !
        IF ( uspp ) THEN
           !
           CALL ZGEMM( 'N', 'N', kdim, nvec, nbase, ONE, spsi, &
                       kdmx, vc, nvecx, ZERO, psi(1,1,nvec+1), kdmx )
           !
           spsi(:,:,1:nvec) = psi(:,:,nvec+1:nvec+nvec)
           !
        END IF
        !
        CALL ZGEMM( 'N', 'N', kdim, nvec, nbase, ONE, hpsi, &
                    kdmx, vc, nvecx, ZERO, psi(1,1,nvec+1), kdmx )
        !
        hpsi(:,:,1:nvec) = psi(:,:,nvec+1:nvec+nvec)
        !
        ! ... refresh the reduced hamiltonian 
        !
        nbase = nvec
        !
        hc(:,1:nbase) = ZERO
        sc(:,1:nbase) = ZERO
        vc(:,1:nbase) = ZERO
        !
        DO n = 1, nbase
           !
!           hc(n,n) = REAL( e(n) )
           hc(n,n) = CMPLX( e(n), 0.0_DP ,kind=DP)
           !
           sc(n,n) = ONE
           vc(n,n) = ONE
           !
        END DO
        !
        CALL stop_clock( 'cegterg:last' )
        !
     END IF
     !
  END DO iterate
  !
  DEALLOCATE( conv )
  DEALLOCATE( ew )
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  res = cudaFreeHost(cptr_vc)
  res = cudaFreeHost(cptr_hc)
  res = cudaFreeHost(cptr_sc)
#else
  DEALLOCATE( vc )
  DEALLOCATE( hc )
  DEALLOCATE( sc )
#endif
  !
  IF ( uspp ) THEN
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
     res = cudaFreeHost(cptr_spsi)
#else
     DEALLOCATE( spsi )
#endif
  END IF
  !
#if defined(__CUDA) && defined(__CUDA_MEM_PINNED)
  res = cudaFreeHost( cptr_hpsi )
  res = cudaFreeHost( cptr_psi )
#else
  DEALLOCATE( hpsi )
  DEALLOCATE( psi )
#endif
  !
  CALL stop_clock( 'cegterg' )
  !
  RETURN
  !
END SUBROUTINE cegterg_gpu
