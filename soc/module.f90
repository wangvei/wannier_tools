!include 'mkl_dss.f90'
  module prec
     !>> A module controls the precision.
     !> when the nnzmax is larger than 2,147,483,647 then li=8,
     !> otherwise, li=4.
     !> warning: li=4 was tested, li=8 is not tested yet.
     integer,parameter :: li=4 ! long integer
     integer,parameter :: Dp=kind(1.0d0) ! double precision
  end module prec

  module wmpi
     use prec

#ifdef MPI
     include 'mpif.h'
#endif

     integer :: cpuid  ! CPU id for mpi
     integer :: num_cpu  ! Number of processors for mpi

#ifdef MPI
     integer, parameter :: mpi_in= mpi_integer
     integer, parameter :: mpi_dp= mpi_double_precision
     integer, parameter :: mpi_dc= mpi_double_complex
     integer, parameter :: mpi_cmw= mpi_comm_world
#endif

     !> Define a structure containing information for doing communication
     type WTParCSRComm

        !> mpi communicator
        integer :: comm

        !> how many cpus that we need to send data on
        integer :: NumSends

        !> which cpus that we need to send data on
        integer, pointer :: SendCPUs(:)

        !> when before we send the vector data to other cpus, we need to get the
        !> data which should be sent, then put these data to a array called
        !> x_buf_data(:). The array SendMapElements(:) gives the position of the
        !> data in vector that should be sent.
        integer, pointer :: SendMapStarts(:)

        !> with this array, we can select the vector data that should be sent
        integer(li), pointer :: SendMapElements(:)

        !> How many cpus that we need to recieve data from
        integer :: NumRecvs

        !> Which cpus that we need to recieve data from
        integer, pointer :: RecvCPUs(:)

        !> When recieved data from other cpus, we need to arrange those data into
        !> an array. The length of this
        integer, pointer :: RecvVecStarts(:)
     end type WTParCSRComm

     !> Define a structure containing information for doing communication
     type WTParVecComm

        !> mpi communicator
        integer :: comm

        !> how many cpus that we need to send data on
        integer :: NumSends

        !> which cpus that we need to send data on
        integer, pointer :: SendCPUs(:)

        !> when before we send the vector data to other cpus, we need to get the
        !> data which should be sent, then put these data to a array called
        !> x_buf_data(:). The array SendMapElements(:) gives the position of the
        !> data in vector that should be sent.
        integer, pointer :: RecvMapStarts(:)

        !> with this array, we can select the vector data that should be sent
        integer(li), pointer :: RecvMapElements(:)

        !> How many cpus that we need to recieve data from
        integer :: NumRecvs

        !> Which cpus that we need to recieve data from
        integer, pointer :: RecvCPUs(:)

        !> When recieved data from other cpus, we need to arrange those data into
        !> an array. The length of this
        integer, pointer :: SendVecStarts(:)

        integer :: NumRowsDiag
        integer :: NumRowsOffd

        integer(li), pointer :: RowMapOffd(:)
        integer(li), pointer :: LocalIndexOffd(:)
        integer(li), pointer :: LocalIndexDiag(:)
     end type WTParVecComm



     !> define a handle for comm, that can be created and destroyed
     type WTCommHandle

        type(WTParCSRComm), pointer :: sendrecv

        integer :: numrequest
        integer, pointer :: mpirequest(:)

        complex(dp), pointer :: senddata(:)
        complex(dp), pointer :: recvdata(:)

     end type WTCommHandle

     integer               :: BasisStart
     integer               :: BasisEnd

     contains

     !> generate partition for any vector with a given length
     subroutine WTGeneratePartition(length, nprocs, part)
        integer(li), intent(in) :: length
        integer, intent(in) :: nprocs
        integer(li), intent(out) :: part(nprocs+1)

        integer :: i
        integer(li) :: div
        integer(li) :: mod1

        mod1= mod(length, nprocs)
        if (mod1.eq.0) then !< each cpu has the same load balance
           div= length/nprocs
           do i=0, nprocs-1
              part(i+1)=1+ i*div
           enddo
        else
           div= length/nprocs+ 1
           do i=0, nprocs
              if (i.ge. (nprocs-mod1)) then
                 part(i+1)= 1+ i*div- (nprocs-mod1)
              else
                 part(i+1)= 1+ i*(div-1) !< the main cpu will get smaller data
              endif
           enddo
        endif
        part(nprocs+1)= length+ 1

        return
     end subroutine WTGeneratePartition

     !> generate local partition for any vector with a given length
     subroutine WTGenerateLocalPartition(length, nprocs, icpu, first, last)
        implicit none
        integer, intent(in) :: nprocs
        integer, intent(in) :: icpu
        integer(li), intent(in) :: length
        integer(li), intent(out) :: first
        integer(li), intent(out) :: last

        integer(li) :: div
        integer(li) :: mod1

        mod1= mod(length, nprocs)
        if (mod1.eq.0) then !< each cpu has the same load balance
           div= length/nprocs
           first=1+ icpu*div
           last=(1+ icpu)*div
        else
           div= length/nprocs+ 1
           if (icpu.ge. (nprocs-mod1)) then
              first= 1+ icpu*div- (nprocs-mod1)
              last= (1+ icpu)*div- (nprocs-mod1)
           else
              first= 1+ icpu*(div-1)
              last= (1+ icpu)*(div-1)!< the main cpu will get smaller data
           endif
        endif

        return
     end subroutine WTGenerateLocalPartition

     !> given the send data, recieve data and sendrecv list, we can use
     !> this subroutine to send and recieve data from other cpus.
     !> when finished this subroutine calls, we need call WTCommHandleDestroy
     !> to check whether the send recv operation is finished
     subroutine WTCommHandleCreate(SendRecv, SendData, RecvData, &
             CommHandle)

        implicit none

        !* in variables
        type(WTParCSRComm), intent(in), pointer :: SendRecv
        complex(dp), pointer :: SendData(:)
        complex(dp), pointer :: RecvData(:)

        !* out variables
        type(WTCommHandle), pointer :: CommHandle

        integer(li) :: VecStart
        integer(li) :: VecLen

        !> sendrecv data
        integer, pointer :: SendCPUs(:)
        integer, pointer :: SendMapStarts(:)
        integer(li), pointer :: SendMapElements(:)
        integer, pointer :: RecvCPUs(:)
        integer, pointer :: RecvVecStarts(:)

        integer :: NumRecvs
        integer :: NumSends
        integer :: NumRequest
        integer, pointer :: MpiRequest(:)

        integer :: ierr
        integer :: comm
        integer :: NCPUs
        integer :: cpu_id

        integer :: i, j
        integer :: icpu

        !* initialize null pointers
        SendCPUs=> Null()
        SendMapStarts=> Null()
        SendMapElements=> Null()
        RecvCPUs=> Null()
        RecvVecStarts=> Null()
        MpiRequest=> Null()

#if defined (MPI)
        comm= SendRecv%Comm
        call mpi_comm_size(comm, NCPUS, ierr)
        call mpi_comm_rank(comm, cpu_id, ierr)
#endif
        NumSends= SendRecv%NumSends
        NumRecvs= SendRecv%NumRecvs
        NumRequest= NumSends+ NumRecvs

        SendCPUs=> SendRecv%SendCPUs
        SendMapStarts=> SendRecv%SendMapStarts
        SendMapElements=> SendRecv%SendMapElements
        RecvCPUs=> SendRecv%RecvCPUs
        RecvVecStarts=> SendRecv%RecvVecStarts

        MpiRequest=> Null()
        if (.not.associated(CommHandle)) allocate(CommHandle)
        allocate(CommHandle%MpiRequest(NumRequest))
        MpiRequest=> CommHandle%MpiRequest

        !> recieve data from other cpus using non-block communication
        j=1
        do i=1, NumRecvs
           icpu= RecvCPUs(i)
           VecStart= RecvVecStarts(i)
           VecLen= RecvVecStarts(i+1)- RecvVecStarts(i)
#if defined (MPI)
           call mpi_irecv(RecvData(VecStart), VecLen, mpi_dc, icpu, &
                          0, comm, MpiRequest(j), ierr)
#endif
           j=j+1
        enddo

        !> send data to other cpus using non-block communication
        do i=1, NumSends
           icpu= SendCPUs(i)
           VecStart= SendMapStarts(i)
           VecLen= SendMapStarts(i+1)- SendMapStarts(i)
#if defined (MPI)
           call mpi_isend(SendData(VecStart), VecLen, mpi_dc, icpu, &
                          0, comm, MpiRequest(j), ierr)
#endif
           j=j+1
        enddo

        CommHandle%NumRequest= NumRequest
        CommHandle%SendData=> SendData
        CommHandle%RecvData=> RecvData
        CommHandle%SendRecv=> SendRecv

        return

     end subroutine WTCommHandleCreate

     subroutine WTCommHandleDestroy(CommHandle)

        implicit none

        type(WTCommHandle), pointer :: CommHandle

        integer :: ierr
        integer :: NumRequest
        integer, pointer :: MpiRequest(:)
        integer, pointer :: MpiStatus(:)

        NumRequest= CommHandle%NumRequest
        MpiRequest=> CommHandle%MpiRequest

        if (.not.associated(CommHandle)) return

        if (NumRequest>0) then
#if defined (MPI)
           allocate(MpiStatus(mpi_status_size*NumRequest))
           call mpi_waitall(NumRequest, MpiRequest, MpiStatus, ierr)
#endif
        endif

        return
     end subroutine WTCommHandleDestroy

     !> define my mpi_allreduce for complex array
     subroutine mp_allreduce_z(comm, ndim, vec, vec_mpi)
        implicit none

        integer, intent(in) :: comm
        integer, intent(in) :: ndim
        complex(dp), intent(in) :: vec(ndim)
        complex(dp), intent(inout) :: vec_mpi(ndim)

        integer :: ierr

        vec_mpi= 0d0

#if defined (MPI)
        call mpi_allreduce(vec, vec_mpi, ndim, &
                           mpi_dc, mpi_sum, comm, ierr)
#else
        vec_mpi= vec
#endif

        return
     end subroutine mp_allreduce_z

  end module wmpi

  module para
     !> Some global parameters
     !
     !> Copyright (c) 2010 QuanSheng Wu. All rights reserved.
     !
     !> add namelist for convenience  June 5th 2016 by QuanSheng Wu

     use wmpi
     use prec
     implicit none

     character(80) :: version

     integer,parameter :: stdout= 8

     !> define the file index to void the same index in different subroutines
     integer, public, save :: outfileindex= 11932

     character(80) :: Hrfile
     character(80) :: Particle
     character(80) :: Package
     character(80) :: KPorTB
     real(dp) :: vef
     logical :: Is_HrFile, Is_Sparse, Use_ELPA
     namelist / TB_FILE / Hrfile, Particle, Package, KPorTB, Is_HrFile, Is_Sparse, Use_ELPA,vef

     !> control parameters
     logical :: BulkBand_calc    ! Flag for bulk energy band calculation
     logical :: BulkBand_plane_calc    ! Flag for bulk energy band calculation for a fixed k plane
     logical :: BulkBand_points_calc    ! Flag for bulk energy band calculation for some k points
     logical :: BulkFS_calc      ! Flag for bulk 3D fermi surface in 3D BZ calculation
     logical :: BulkFS_plane_calc ! Flag for bulk fermi surface for a fix k plane calculation
     logical :: BulkGap_cube_calc  ! Flag for Gap_cube calculation
     logical :: BulkGap_plane_calc ! Flag for Gap_plane calculation
     logical :: SlabBand_calc  ! Flag for 2D slab energy band calculation
     logical :: SlabBandWaveFunc_calc  ! Flag for 2D slab band wave function
     logical :: SlabBand_plane_calc  ! Flag for 2D slab energy band calculation
     logical :: WireBand_calc  ! Flag for 1D wire energy band calculation
     logical :: SlabSS_calc    ! Flag for surface state ARPES spectrum calculation
     logical :: Dos_calc       ! Flag for density of state calculation
     logical :: JDos_calc      ! Flag for joint density of state calculation
     logical :: SlabArc_calc   ! Flag for surface state fermi-arc calculation
     logical :: SlabQPI_calc   ! Flag for surface state QPI spectrum calculation
     logical :: ArcQPI_calc   ! Flag for surface state QPI spectrum calculation
     logical :: SlabSpintexture_calc ! Flag for surface state spin-texture calculation
     logical :: WannierCenter_calc  ! Flag for Wilson loop calculation
     logical :: Z2_3D_calc  ! Flag for Z2 number calculations of 6 planes
     logical :: WeylChirality_calc  ! Weyl chirality calculation
     logical :: NLChirality_calc  ! Chirality calculation for nodal line
     logical :: Chern_3D_calc  ! Flag for Chern number calculations of 6 planes
     logical :: MirrorChern_calc  ! Flag for mirror Chern number calculations
     logical :: BerryPhase_calc   ! Flag for Berry phase calculation
     logical :: BerryCurvature_calc ! Flag for Berry curvature calculation
     logical :: BerryCurvature_EF_calc ! Flag for Berry curvature calculation at Fermi level E_arc
     logical :: BerryCurvature_slab_calc ! Flag for Berry curvature calculation for a slab system
     logical :: EffectiveMass_calc  ! Flag for effective mass calculation
     logical :: FindNodes_calc  ! Flag for effective mass calculation
     logical :: TBtoKP_calc  ! Flag for kp model construction from tight binding model
     logical :: Hof_Butt_calc  ! Flag for Hofstader butterfly
     logical :: LandauLevel_B_calc  ! Flag for Hofstader butterfly
     logical :: LOTO_correction  ! Flag for LOTO correction of phonon spectrum
     logical :: Boltz_OHE_calc  ! Flag for Boltzmann tranport under magnetic field
     logical :: Symmetry_Import_calc  ! Flag for Boltzmann tranport under magnetic field using symmetry
     logical :: Boltz_evolve_k  ! Flag for Boltzmann tranport under magnetic field
     logical :: Boltz_k_calc  ! Flag for Boltzmann tranport under magnetic field
     logical :: AHC_calc  ! Flag for Boltzmann tranport under magnetic field
     logical :: LandauLevel_k_calc  ! Flag for landau level calculation along k direction with fixed B
     logical :: LandauLevel_kplane_calc  ! Flag for landau level calculation along in a kplane in the magnetic BZ
     logical :: LandauLevel_k_dos_calc  ! Flag for landau level spectrum mode calculation along k direction with fixed B
     logical :: LandauLevel_B_dos_calc  ! Flag for landau level spectrum mode calculation for different B with given k point
     logical :: LandauLevel_wavefunction_calc  ! Flag for landau level calculation along k direction with fixed B
     logical :: OrbitalTexture_calc  ! Flag for Orbital texture calculation in a given k plane
     logical :: OrbitalTexture_3D_calc  ! Flag for Orbital texture calculation in a given k plane
     logical :: Fit_kp_calc  ! Flag for fitting kp model
     logical :: DMFT_MAG_calc  ! DMFT loop in uniform magnetic field
     logical :: LanczosSeqDOS_calc  ! DOS
     logical :: Translate_to_WS_calc  ! whether translate the k points into the Wigner-Seitz cell

     logical :: LanczosBand_calc=.false.
     logical :: LanczosDos_calc= .false.
     logical :: landau_chern_calc = .false.

     namelist / Control / BulkBand_calc,BulkFS_calc,  BulkFS_Plane_calc, BulkGap_plane_calc, &
                          BulkBand_points_calc, SlabBand_plane_calc, &
                          BulkGap_cube_calc, SlabBand_calc, SlabBandWaveFunc_calc, WireBand_calc, &
                          SlabSS_calc, SlabArc_calc, SlabSpintexture_calc, &
                          WannierCenter_calc,BerryPhase_calc,BerryCurvature_calc, &
                          BerryCurvature_EF_calc, BerryCurvature_slab_calc, MirrorChern_calc, &
                          Z2_3D_calc, Chern_3D_calc, WeylChirality_calc, NLChirality_calc, &
                          Dos_calc, JDos_calc, EffectiveMass_calc, SlabQPI_calc, ArcQPI_calc, &
                          FindNodes_calc, TBtoKP_calc, LOTO_correction, &
                          BulkBand_plane_calc, Hof_Butt_calc, Symmetry_Import_calc, &
                          Boltz_k_calc, Boltz_evolve_k, Boltz_OHE_calc, AHC_Calc, &
                          LandauLevel_k_calc, OrbitalTexture_calc, OrbitalTexture_3D_calc, &
                          LandauLevel_wavefunction_calc, Fit_kp_calc, DMFT_MAG_calc, &
                          LanczosSeqDOS_calc, Translate_to_WS_calc, LandauLevel_k_dos_calc, &
                          LandauLevel_B_dos_calc,LanczosBand_calc,LanczosDos_calc, &
                          LandauLevel_B_calc, LandauLevel_kplane_calc,landau_chern_calc

     integer :: Nslab  ! Number of slabs for 2d Slab system
     integer :: Nslab1 ! Number of slabs for 1D wire system
     integer :: Nslab2 ! Number of slabs for 1D wire system

     integer :: Np !> Number of princple layers for surface green's function

     integer, public, save :: ijmax=6

     integer :: Ndim !> Leading dimension of surface green's function

     integer :: Numoccupied !> Number of occupied bands for bulk unit cell


     integer :: Ntotch !> Number of electrons

     integer :: Num_wann  ! Number of Wannier functions

     integer :: Nrpts ! Number of R points


     integer :: Nk   ! number of k points for different use
     integer :: Nk1  ! number of k points for different use
     integer :: Nk2  ! number of k points for different use
     integer :: Nk3  ! number of k points for different use
     integer, parameter :: Nk2_max= 4096   ! maximum number of k points

     integer, public, save :: Nr1=5
     integer, public, save :: Nr2=5
     integer, public, save :: Nr3=2


     integer,parameter :: kmesh(2)=(/200 , 200/)  ! kmesh used for spintexture
     integer,parameter :: knv=kmesh(1)*kmesh(2)  ! number of k points used for spintexture


     integer :: Soc  ! A parameter to control soc;  Soc=0 means no spin-orbit coupling; Soc>0 means spin-orbit coupling


     real(Dp) :: eta     ! used to calculate dos epsilon+i eta
     real(Dp) :: Eta_Arc ! used to calculate dos epsilon+i eta


     integer :: OmegaNum   ! The number of energy slices between OmegaMin and OmegaMax

     integer :: NumLCZVecs  !> number of Lanczos vectors
     integer :: NumSelectedEigenVals  !> number of Selected eigen values

     integer :: NumRandomConfs  !> number of random configurations, used in the Lanczos DOS calculation, default is 1

     !~      real(dp) :: vef
     real(dp) :: OmegaMin, OmegaMax ! omega interval


     real(Dp) :: E_arc ! Fermi energy for arc calculation


     real(Dp) :: Gap_threshold  ! threshold value for output the the k points data for Gap3D

     !>> some parameters for DMFT
     !> The inverse of temperature Beta= 1/(KB*T), Beta*T=11600, T is in unit of Kelvin
     real(dp) :: Beta

     !> temperature related parameters, read from input.dat
     !> be used to define a range of temperatures, in units of Kelvin
     real(dp) :: Tmin
     real(dp) :: Tmax
     integer :: NumT

     !> magnetic field times time in units of Tesla*ps
     real(dp) :: BTauMax
     integer :: NBTau
     integer :: Nslice_BTau_Max

     !> cut of radial for summation over R vectors
     real(dp) :: Rcut

     !> a integer to control the magnetic filed, Magp should smaller than Nq
     integer :: Magp

     !>> parameters for wilson loop calculation (Wannier charge center)

     !> the difference of the wilson loop between two neighbouring k points
     real(dp) :: wcc_neighbour_tol
     real(dp) :: wcc_calc_tol

     !> namelist parameters
     namelist /PARAMETERS/ Eta_Arc, OmegaNum, OmegaMin, OmegaMax, &
        E_arc, Nk1, Nk2, Nk3, NP, Gap_threshold, Tmin, Tmax, NumT, NBTau, BTauMax, Rcut, Magp, Nslice_BTau_Max, &
        wcc_neighbour_tol, wcc_calc_tol, Beta,NumLCZVecs, NumRandomConfs, NumSelectedEigenVals


     real(Dp) :: E_fermi  ! Fermi energy, search E-fermi in OUTCAR for VASP, set to zero for Wien2k

     real(dp) :: surf_onsite  !> surface onsite energy shift

     real(dp) :: Bx, By, Bz !> magnetic field (in Tesla)
     real(dp) :: Btheta, Bphi !> magnetic field direction, Bx=cos(theta)*sin(phi), By=sin(theta)*sin(phi), Bz=cos(phi)
     real(dp) :: Bmagnitude  ! sqrt(Bx*Bx+By*By+Bz*Bz)
     real(dp) :: Bdirection(3) !> a unit vector to represent the direction of B.

     !> system parameters namelist
     namelist / SYSTEM / Soc, E_fermi, Bx, By, Bz, Btheta, Bphi, surf_onsite, &
        Nslab, Nslab1, Nslab2, Numoccupied, Ntotch

     real(dp),parameter :: alpha= 1.20736d0*1D-6  !> e/2/h*a*a   a=1d-10m, h is the planck constant then the flux equals alpha*B*s

     !> some parameters related to atomic units
     real(dp),parameter :: bohr2atomic=0.529177211d0  ! Bohr to atomic length unit
     real(dp),parameter :: eV2Hartree= 1d0/27.211385d0 ! electron Voltage to Hartree unit
     real(dp),parameter :: Echarge= 1.602189E-19    ! electron charge in SI unit
     real(dp),parameter :: hbar= 1.054589E-34    ! electron charge in SI unit
     real(dp),parameter :: epsilon0= 8.85418781762E-12    ! dielectric constant in SI unit


     !real(dp),parameter :: Pi= 3.14159265359d0  ! circumference ratio pi
     real(dp),parameter ::  Pi= 3.14159265358979d0  ! circumference ratio pi
     real(dp),parameter :: half= 0.5d0  ! 1/2
     real(dp),parameter :: zero= 0.0d0  ! 0
     real(dp),parameter :: one = 1.0d0  ! 1
     real(dp),parameter :: eps3= 1e-3   ! 0.001
     real(dp),parameter :: eps6= 1e-6   ! 0.000001
     real(dp),parameter :: eps8= 1e-8   ! 0.000001
     real(dp),parameter :: eps9= 1e-9   ! 0.000000001
     real(dp),parameter :: eps12= 1e-12   ! 0.000000000001
     complex(dp),parameter :: zzero= 0.0d0  ! 0

     real(Dp),parameter :: Ka(2)=(/1.0d0,0.0d0/)
     real(Dp),parameter :: Kb(2)=(/0.0d0,1.0d0/)

     real(Dp),public, save :: Ra2(2)
     real(Dp),public, save :: Rb2(2)

     real(Dp),public, save :: Ka2(2)
     real(Dp),public, save :: Kb2(2)


     real(dp),public, save :: Rua(3) ! three  primitive vectors in Cartsien coordinatec, a
     real(dp),public, save :: Rub(3) ! three  primitive vectors in Cartsien coordinatec, b
     real(dp),public, save :: Ruc(3) ! three  primitive vectors in Cartsien coordinatec, c


     real(dp),public, save :: Rua_new(3) !> three primitive vectors in new coordinate system, see slab part
     real(dp),public, save :: Rub_new(3) !> three primitive vectors in new coordinate system, see slab part
     real(dp),public, save :: Ruc_new(3) !> three primitive vectors in new coordinate system, see slab part

     !> magnetic supercell
     real(dp),public, save :: Rua_mag(3) ! three  primitive vectors in Cartsien coordinatec
     real(dp),public, save :: Rub_mag(3) ! three  primitive vectors in Cartsien coordinatec
     real(dp),public, save :: Ruc_mag(3) ! three  primitive vectors in Cartsien coordinatec

     real(dp),public, save :: Kua(3)   ! three reciprocal primitive vectors
     real(dp),public, save :: Kub(3)   ! three reciprocal primitive vectors
     real(dp),public, save :: Kuc(3)   ! three reciprocal primitive vectors

     !> reciprocal lattice for magnetic supercell
     real(dp),public, save :: Kua_mag(3)   ! three reciprocal primitive vectors
     real(dp),public, save :: Kub_mag(3)   ! three reciprocal primitive vectors
     real(dp),public, save :: Kuc_mag(3)   ! three reciprocal primitive vectors

     real(dp),public, save :: Urot(3, 3)  ! Rotate matrix for the new primitve cell

     ! k list for 3D case band
     integer :: nk3lines  ! Howmany k lines for bulk band calculation
     integer :: nk3_band  ! Howmany k points for each k line
     character(4), allocatable :: k3line_name(:) ! Name of the K points
     real(dp),allocatable :: k3line_stop(:)  ! Connet points
     real(dp),allocatable :: k3line_start(:, :) ! Start point for each k line
     real(dp),allocatable :: k3line_end(:, :) ! End point for each k line
     real(dp),allocatable :: K3list_band(:, :) ! coordinate of k points for bulk band calculation in kpath mode
     real(dp),allocatable :: K3len(:)  ! put all k points in a line in order to plot the bands
     real(dp),allocatable :: K3points(:, :) ! coordinate of k points for bulk band calculation in cube mode

     !> k points in the point mode
     integer :: Nk3_point_mode
     real(dp), allocatable :: k3points_pointmode_cart(:, :)
     real(dp), allocatable :: k3points_pointmode_direct(:, :)


     !> kpath for magnetic supercell
     real(dp),allocatable :: K3len_mag(:)  ! put all k points in a line in order to plot the bands
     real(dp),allocatable :: k3line_mag_stop(:)  ! Connet points

     ! k path for berry phase, read from the input.dat
     ! in the KPATH_BERRY card
     integer :: NK_Berry
     character(10) :: DirectOrCart_Berry ! Whether direct coordinates or Cartisen coordinates
     real(dp), allocatable :: k3points_Berry(:, :) ! only in direct coordinates

     !>> top surface atoms
     integer :: NtopAtoms, NtopOrbitals  ! Select atoms on the top surface for surface state output
     integer, allocatable :: TopAtoms(:)  ! Select atoms on the top surface for surface state output
     integer, allocatable :: TopOrbitals(:)  ! Orbitals on the top surface for surface state output

     !>> bottom surface atoms
     integer :: NBottomAtoms, NBottomOrbitals ! Select atoms on the bottom  surface for surface state output
     integer, allocatable :: BottomAtoms(:) ! Select atoms on the bottom  surface for surface state output
     integer, allocatable :: BottomOrbitals(:) ! Orbitals on the bottom  surface for surface state output

     !>> effective mass
     real(dp), public, save :: dk_mass  ! k step for effective mass calculation
     integer , public, save :: iband_mass   ! the i'th band for effective mass calculation
     real(dp), public, save :: k_mass(3) ! the k point for effective mass calculation

     !>  klist for 2D case include all 2D system
     integer :: nk2lines  ! Number of k lines for 2D slab band calculation
     integer :: knv2 ! Number of k points for each k line
     real(dp) :: kp(2, 32) ! start k point for each k line
     real(dp) :: ke(2, 32) ! end k point for each k line
     real(dp) :: k2line_stop(32)
     character(4) :: k2line_name(32)
     real(dp),allocatable :: k2len(:)
     real(dp),allocatable :: k2_path(:, :)

     !> A kpoint for 3D system--> only one k point
     real(dp), public, save :: Kpoint_3D_direct(3) ! the k point for effective mass calculation
     real(dp), public, save :: Kpoint_3D_cart(3) ! the k point for effective mass calculation

     character(10) :: DirectOrCart_SINGLE ! Whether direct coordinates or Cartisen coordinates
     real(dp), public, save :: Single_KPOINT_3D_DIRECT(3) ! the k point for effective mass calculation
     real(dp), public, save :: Single_KPOINT_3D_CART(3) ! the k point for effective mass calculation
     real(dp), public, save :: Single_KPOINT_2D_DIRECT(2) ! a single k point in the 2D slab BZ
     real(dp), public, save :: Single_KPOINT_2D_CART(2) 

     !> kpoints plane for 2D system--> arcs
     real(dp) :: K2D_start(2)   ! start k point for 2D system calculation, like arcs
     real(dp) :: K2D_vec1(2) ! the 1st k vector for the k plane
     real(dp) :: K2D_vec2(2) ! the 2nd k vector for the k plane

     !> kpoints plane for 3D system --> gapshape
     real(dp) :: K3D_start(3) ! the start k point for the 3D k plane
     real(dp) :: K3D_vec1(3) ! the 1st k vector for the 3D k plane
     real(dp) :: K3D_vec2(3) ! the 2nd k vector for the 3D k plane
     real(dp) :: K3D_vec3(3)

     !> kpoints plane for 3D system --> gapshape3D
     real(dp) :: K3D_start_cube(3) ! the start k point for the k cube
     real(dp) :: K3D_vec1_cube(3) ! the 1st k vector for the k cube
     real(dp) :: K3D_vec2_cube(3) ! the 2nd k vector for the k cube
     real(dp) :: K3D_vec3_cube(3) ! the 3rd k vector for the k cube

     integer, allocatable     :: irvec(:,:)   ! R coordinates in fractional units
     real(dp), allocatable    :: crvec(:,:)   ! R coordinates in Cartesian coordinates in units of Angstrom
     complex(dp), allocatable :: HmnR(:,:,:)   ! Hamiltonian m,n are band indexes


     !sparse HmnR arraies
     integer,allocatable :: hicoo(:),hjcoo(:),hirv(:)
     complex(dp),allocatable :: hacoo(:)
     integer :: splen


     integer, allocatable     :: ndegen(:)  ! degree of degeneracy of R point

     complex(dp), allocatable :: HmnR_newcell(:,:,:)   ! Hamiltonian m,n are band indexes
     real(dp), allocatable :: Atom_position_cart_newcell(:,:)   ! Hamiltonian m,n are band indexes
     real(dp), allocatable :: Atom_position_direct_newcell(:,:)   ! Hamiltonian m,n are band indexes
     integer, allocatable     :: irvec_newcell(:,:)   ! R coordinates
     integer, allocatable     :: ndegen_newcell(:)  ! degree of degeneracy of R point
     real(dp),public, save :: Rua_newcell(3) !> three rotated primitive vectors in old coordinate system
     real(dp),public, save :: Rub_newcell(3) !> three rotated primitive vectors in old coordinate system
     real(dp),public, save :: Ruc_newcell(3) !> three rotated primitive vectors in old coordinate system
     real(dp),public, save :: Kua_newcell(3)   ! three reciprocal primitive vectors, a
     real(dp),public, save :: Kub_newcell(3)   ! three reciprocal primitive vectors, b
     real(dp),public, save :: Kuc_newcell(3)   ! three reciprocal primitive vectors, c

     complex(dp),parameter    :: zi=(0.0d0, 1.0d0)    ! complex constant 0+1*i
     complex(dp),parameter    :: pi2zi=(0.0d0, 6.283185307179586d0) ! 2*pi*zi

     !> define surface
     real(dp), public, save :: Umatrix(3, 3)    ! a matrix change old primitive cell to new primitive cell which can define new surface, it is a 3*3 matrix
     integer, public, save :: MillerIndices(3)    ! a matrix change old primitive cell to new primitive cell which can define new surface, it is a 3*3 matrix

     integer :: Num_atoms  ! number of atoms in one primitive cell
     integer :: Num_atom_type  ! number of atom's type in one primitive cell
     integer, allocatable :: Num_atoms_eachtype(:)  ! number of atoms for each atom's type in one primitive cell
     character(10), allocatable :: Name_of_atomtype(:)  ! type of atom
     integer, allocatable :: itype_atom(:)  ! type of atom

     character(10) :: AngOrBohr  ! Angstrom unit to Bohr unit
     character(10) :: DirectOrCart ! Whether direct coordinates or Cartisen coordinates
     character(10), allocatable :: Atom_name(:)  ! Atom's name
     real(dp) :: CellVolume ! Cell volume
     real(dp) :: MagneticSuperCellVolume ! Cell volume
     real(dp) :: MagneticSuperProjectedArea !Projected area respect to the first vector specifed in SURFACE card in Angstrom^2
     real(dp) :: kCubeVolume
     real(dp) :: ReciprocalCellVolume
     real(dp) :: MagneticReciprocalCellVolume
     real(dp), allocatable :: Atom_position(:, :)  ! Atom's position, only the atoms which have Wannier orbitals
     real(dp), allocatable :: Atom_position_direct(:, :)
     real(dp), allocatable :: wannier_centers_cart(:, :)
     real(dp), allocatable :: wannier_centers_direct(:, :)
     real(dp), allocatable :: Atom_magnetic_moment(:, :)  ! magnetic moment

     integer :: max_projs
     integer, allocatable :: nprojs(:) ! Number of projectors for each atoms
     character(10), allocatable :: proj_name(:, :)

     !> the start index for each atoms, only consider the spinless component
     integer, allocatable :: orbitals_start(:)

     !> symmetry operator apply on function basis
     complex(dp), allocatable :: inversion(:, :)
     complex(dp), allocatable :: mirror_x(:, :)
     complex(dp), allocatable :: mirror_y(:, :)
     complex(dp), allocatable :: mirror_z(:, :)
     complex(dp), allocatable :: glide(:, :)

     !> symmetry operator apply on coordinate system
     real(dp), allocatable :: inv_op(:, :)
     real(dp), allocatable :: mirror_z_op(:, :)
     real(dp), allocatable :: mirror_x_op(:, :)
     real(dp), allocatable :: mirror_y_op(:, :)
     real(dp), allocatable :: glide_y_op(:, :)

     !> weyl point information from the input.dat
     integer :: Num_Weyls
     character(10) :: DirectOrCart_Weyl   ! Whether direct coordinates or Cartisen coordinates
     real(dp) :: kr0
     real(dp), allocatable :: weyl_position_cart(:, :)
     real(dp), allocatable :: weyl_position_direct(:, :)

     !> nodal loop information from the input.dat
     integer :: Num_NLs
     character(10) :: DirectOrCart_NL   ! Whether direct coordinates or Cartisen coordinates
     real(dp) :: Rbig_NL
     real(dp) :: rsmall_NL
     real(dp), allocatable :: NL_center_position_cart(:, :)
     real(dp), allocatable :: NL_center_position_direct(:, :)


     !> parameters for tbtokp
     integer :: Num_selectedbands_tbtokp
     integer, allocatable :: Selected_bands_tbtokp(:)
     real(dp) :: k_tbtokp(3)   ! The K point that used to construct kp model


     !> for phonon LO-TO correction. By T.T Zhang
     real(dp), public, save :: Diele_Tensor(3, 3) ! di-electric tensor
     real(dp), allocatable :: Born_Charge(:, :, :)
     real(dp), allocatable :: Atom_Mass(:)

     real(dp), parameter :: VASPToTHZ= 29.54263748d0 ! By T.T zhang

     type kcube_type
        !> define a module for k points in BZ in purpose of MPI

        integer :: Nk_total
        integer :: Nk_current
        integer :: Nk_start
        integer :: Nk_end
        integer, allocatable  :: ik_array(:)
        integer, allocatable  :: IKleft_array(:)

        real(dp), allocatable :: Ek_local(:)
        real(dp), allocatable :: Ek_total(:)
        real(dp), allocatable :: k_direct(:, :)
        real(dp), allocatable :: weight_k(:)

        !> velocities
        real(dp), allocatable :: vx_local(:)
        real(dp), allocatable :: vx_total(:)
        real(dp), allocatable :: vy_local(:)
        real(dp), allocatable :: vy_total(:)
        real(dp), allocatable :: vz_local(:)
        real(dp), allocatable :: vz_total(:)
        real(dp), allocatable :: weight_k_local(:)
     end type kcube_type

     type(kcube_type) :: KCube3D

     !> gather the reduced k points and the original k points
     type kcube_type_symm
        !> Nk1*Nk2*Nk3
        integer :: Nk_total
        !> total number of reduced k points
        integer :: Nk_total_symm
        !> relate the full kmesh to the reduced k point
        integer, allocatable :: ik_relate(:)
        !> reduced k points
        integer, allocatable :: ik_array_symm(:)
        real(dp), allocatable :: weight_k(:)
     end type kcube_type_symm

     type(kcube_type_symm) :: KCube3D_symm

     !> Select those atoms which used in the construction of the Wannier functions
     !> It can be useful when calculate the projected weight related properties
     !> such as the surface state, slab energy bands.
     integer :: NumberofSelectedAtoms
     integer, allocatable :: Selected_Atoms(:)

     !> selected wannier orbitals
     !> this part can be read from the input.dat or wt.in file
     !> if not specified in the input.dat or wt.in, we will try to specify it from  the
     !> SelectedAtoms part.
     integer :: NumberofSelectedOrbitals
     integer, allocatable :: Selected_WannierOrbitals(:)

     !> selected bands for magnetoresistance
     integer :: NumberofSelectedBands
     integer, allocatable :: Selected_band_index(:)

     !> index for non-spin polarization
     integer, allocatable :: index_start(:)
     integer, allocatable :: index_end(:)


     !> time
     character(8)  :: date_now
     character(10) :: time_now
     character(5)  :: zone_now


     !> total number of symmetry operators in the system
     integer :: number_group_generators
     integer :: number_group_operators

     !> point group generator operation defined by the BasicOperations_space
     integer , allocatable :: generators_find(:)

     !> translation operator generators in fractional/direct coordinate
     real(dp), allocatable :: tau_find(:,:)

     !> point group operators in cartesian and direct coordinate
     real(dp), allocatable :: pggen_cart(:, :, :)
     real(dp), allocatable :: pggen_direct(:, :, :)

     !> space group operators in cartesian and direct coordinate
     real(dp), allocatable :: pgop_cart(:, :, :)
     real(dp), allocatable :: pgop_direct(:, :, :)
     real(dp), allocatable :: tau_cart(:,:)
     real(dp), allocatable :: tau_direct(:,:)
     real(dp), allocatable :: spatial_inversion(:)


 end module para


 module wcc_module
    ! module for Wannier charge center (Wilson loop) calculations.
    use para
    implicit none


    type kline_wcc_type
       ! define a type of all properties at the k point to get the wcc
       real(dp) :: k(3)  ! coordinate
       real(dp) :: delta ! apart from the start point
       real(dp), allocatable :: wcc(:)  ! 1:Numoccupied, wannier charge center
       real(dp), allocatable :: gap(:)  ! 1:Numoccupied, the distance between  wcc neighbours
       real(dp) :: largestgap_pos_i     ! largest gap position
       real(dp) :: largestgap_pos_val   ! largest gap position value
       real(dp) :: largestgap_val       ! largest gap value
       logical  :: converged            ! converged or not
       logical  :: calculated
    end type kline_wcc_type

    type kline_integrate_type
       ! define a type of all properties at the k point for integration
       real(dp) :: k(3)  ! coordinate
       real(dp) :: delta ! apart from the start point
       real(dp) :: b(3)  ! dis
       logical  :: calculated
       complex(dp), allocatable :: eig_vec(:, :)  !dim= (num_wann, num_wann)
    end type kline_integrate_type

 end module wcc_module

