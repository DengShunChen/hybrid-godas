program bgvar
  use hzsmooth
  use netcdf
  use datatable
  implicit none

  ! variables read in from namelist
  integer :: grid_nx
  integer :: grid_ny
  integer :: grid_nz

  real :: hz_loc(2) = (/200e3, 20e3/)
  real :: hz_loc_scale = 2.5

  real :: t_varmin_len        = -1
  real :: t_varmin_do         = -1
  real :: t_varmin_surf_const = -1
  real :: t_varmax            = -1
  real :: t_dz                = -1

  real :: s_varmin_len        = -1
  real :: s_varmin_do         = -1
  real :: s_varmin_surf_const = -1
  real :: s_varmax            = -1
  real :: s_dz                = -1

  integer :: gauss_iter = 2

  ! data fields read in
  real,  allocatable :: grid_lat(:,:)
  real,  allocatable :: grid_lon(:,:)
  real,  allocatable :: grid_mask(:,:)
  real,  allocatable :: grid_dpth(:)
  real,  allocatable :: grid_D(:,:)
  real,  allocatable :: bg_t(:,:,:)
  real,  allocatable :: bg_vtloc(:,:,:)

  ! calculated data fields
  integer, allocatable :: grid_btm(:,:)
  real,    allocatable :: grid_ld(:,:)
  real,    allocatable :: bgvar_t(:,:,:)
  real,    allocatable :: bgvar_s(:,:,:)
  real,    allocatable :: t_varmin_surf(:,:)
  real,    allocatable :: s_varmin_surf(:,:)

  !OpenMP functions
  INTEGER :: OMP_GET_NUM_THREADS, OMP_GET_THREAD_NUM

  !other misc variables
  integer :: unit
  integer :: nc, nc_x, nc_y, nc_z, nc_v
  integer :: x, y, z, z2, btm
  real :: r, r3
  real, allocatable :: t_r1(:), s_r1(:)
  real, allocatable :: r2(:)

  ! constants
  real, parameter :: pi = 4*atan(1.0)
  real, parameter :: re = 6371d3
  real, parameter :: omega = 7.29e-5

! use this to get the repository version at compile time
#ifndef CVERSION
#define CVERSION "Unknown"
#endif

#ifndef CTIME
#define CTIME "Unknown"
#endif

  namelist /g3dv_grid/ grid_nx, grid_ny, grid_nz
  namelist /g3dv_hzloc/ hz_loc, hz_loc_scale
  namelist /bgvar_nml/  t_varmin_len, t_varmin_do, t_varmin_surf_const, t_varmax, t_dz, &
       s_varmin_len, s_varmin_do, s_varmin_surf_const, s_varmax, s_dz, gauss_iter


  print *, "------------------------------------------------------------"
  print *, " GODAS-3DVar background error variance"
  print *, ""
  print *, " version:  ", CVERSION
  print *, " compiled: ", CTIME
  print *, "------------------------------------------------------------"

!$OMP PARALLEL
  if(OMP_GET_THREAD_NUM() == 0) then
     print *, "OpenMP threads: ", OMP_GET_NUM_THREADS()
     print *, ""
  end if
!$OMP END PARALLEL

  ! read in namelist
  open(newunit=unit, file="namelist.3dvar", status="old")

  read(unit, nml=g3dv_grid)
  print g3dv_grid
  
  rewind(unit)  
  read(unit, nml=g3dv_hzloc)
  print g3dv_hzloc

  rewind(unit)
  read(unit, nml=bgvar_nml)
  print bgvar_nml

  close(unit)

  ! read in the data files
  print *, ""
  print *, "------------------------------------------------------------"
  print *, "reading data fields"
  print *, ""

  call datatable_init(.true., "datatable.3dvar")

  allocate(grid_mask(grid_nx,grid_ny))
  call datatable_get('grid_mask', grid_mask)

  allocate(grid_D(grid_nx, grid_ny))
  call datatable_get('grid_D', grid_D)

  allocate(grid_dpth(grid_nz))
  call datatable_get('grid_z', grid_dpth)

  allocate(grid_lon(grid_nx, grid_ny))
  call datatable_get('grid_x', grid_lon)

  allocate(grid_lat(grid_nx, grid_ny))
  call datatable_get('grid_y', grid_lat)

  allocate(bg_t(grid_nx, grid_ny, grid_nz))
  call datatable_get('bg_t', bg_t)

  allocate(bg_vtloc(grid_nx, grid_ny, grid_nz))
  call datatable_get('vtloc', bg_vtloc)

  allocate(t_varmin_surf(grid_nx, grid_ny)) 
  if (t_varmin_surf_const < 0) then
     call datatable_get('t_varmin_surf', t_varmin_surf)
  else
     t_varmin_surf = t_varmin_surf_const
  end if

  allocate(s_varmin_surf(grid_nx, grid_ny)) 
  if (s_varmin_surf_const < 0) then
     call datatable_get('s_varmin_surf', s_varmin_surf)
  else
     s_varmin_surf = s_varmin_surf_const
  end if


  print *, ""
  print *, "------------------------------------------------------------"
  print *, ""


  ! calculate the bottom levels
  !------------------------------
  print *, "Calculating bottom levels..."
  allocate(grid_btm(grid_nx, grid_ny))
  grid_btm = 0
!$OMP PARALLEL DO PRIVATE(x,z) SCHEDULE(static,1)
  do y = 1, grid_ny
     do x=1, grid_nx
        if(grid_mask(x,y) < 1.0) cycle
        do z= 1, grid_nz
           if(grid_dpth(z) > grid_D(x,y)) then
              grid_btm(x,y) = z-1
              exit
           end if
           grid_btm(x,y) = grid_nz
        end do
     end do
  end do
!$OMP END PARALLEL DO


  ! calculate horizontal localization distances
  allocate(grid_ld(grid_nx,grid_ny))
  do y=1, grid_ny
     do x=1,grid_nx
        grid_ld(x,y) = sqrt(bgcov_hzdist(grid_lat(x,y))**2/gauss_iter)
     end do
  end do




  ! calculate dt/dz
  !------------------------------
  print *, "calculating vertical profiles..."
  allocate(t_r1(grid_nz))
  allocate(s_r1(grid_nz))
  allocate(r2(grid_nz))
  allocate(bgvar_t(grid_nx, grid_ny, grid_nz))
  allocate(bgvar_s(grid_nx, grid_ny, grid_nz))

  bgvar_t = 0.0
  bgvar_s = 0.0
!$OMP PARALLEL DO PRIVATE(x,btm,z,r,t_r1,s_r1,r2) SCHEDULE(static, 1)
  do y=1,grid_ny
     do x=1,grid_nx
        btm = grid_btm(x,y)
        if(btm ==0) cycle

        ! calculate profile minimums
        ! r1 = minimum values
        do z=1,grid_nz
           t_r1(z) = t_varmin_do + (t_varmin_surf(x,y) - t_varmin_do)*exp((grid_dpth(1) - grid_dpth(z))/ t_varmin_len)
           s_r1(z) = s_varmin_do + (s_varmin_surf(x,y) - s_varmin_do)*exp((grid_dpth(1) - grid_dpth(z))/ s_varmin_len)
        end do

        ! calculate dT/Dz
        ! r2 = error calculated from dt/dz
        r2 = 0.0
        r2(1) = (bg_t(x,y,2)-bg_t(x,y,1)) / (grid_dpth(2)-grid_dpth(1))
        do z = 2, btm-1
           r2(z) = (bg_t(x,y,z+1)-bg_t(x,y,z-1)) / (grid_dpth(z+1)-grid_dpth(z-1))
        end do
        r2(btm) = (bg_t(x,y,btm)-bg_t(x,y,btm-1)) / (grid_dpth(btm)-grid_dpth(btm-1))
        

        !combine calculated dt/dz with the calculated minimums
        t_r1(1:btm) = max(min(abs(r2(1:btm))*t_dz,t_varmax), t_r1(1:btm))
        s_r1(1:btm) = max(min(abs(r2(1:btm))*s_dz,s_varmax), s_r1(1:btm))
        

        ! vertical smoothing
        call vtsmooth(t_r1(1:btm), bg_vtloc(x,y,:))
        call vtsmooth(s_r1(1:btm), bg_vtloc(x,y,:))


        bgvar_t(x,y,1:btm) = t_r1(1:btm)
        bgvar_s(x,y,1:btm) = s_r1(1:btm)
     end do
  end do
!$OMP END PARALLEL DO


  ! perform hoziaontal smoothing
  print *, "gaussian smoother..."
  call hzsmooth_gauss(bgvar_t, grid_lat, grid_lon, grid_btm, grid_ld, gauss_iter)
  call hzsmooth_gauss(bgvar_s, grid_lat, grid_lon, grid_btm, grid_ld, gauss_iter)


  ! write the output
  print *, ""
  print *, "------------------------------------------------------------"
  print *, "Saving output"
  call check(nf90_create("bgvar.nc", nf90_write, nc))
  call check(nf90_def_dim(nc, "x", grid_nx, nc_x))
  call check(nf90_def_var(nc, "x", nf90_real, (/nc_x/), nc_v))
  call check(nf90_put_att(nc, nc_v, "units", "degrees_east"))

  call check(nf90_def_dim(nc, "y", grid_ny, nc_y))
  call check(nf90_def_var(nc, "y", nf90_real, (/nc_y/), nc_v))
  call check(nf90_put_att(nc, nc_v, "units", "degrees_north"))

  call check(nf90_def_dim(nc, "z", grid_nz, nc_z))
  call check(nf90_def_var(nc, "z", nf90_real, (/nc_z/), nc_v))
  call check(nf90_put_att(nc, nc_v, "units", "meters"))

  call check(nf90_def_var(nc, "bgvar_t", nf90_real, (/nc_x, nc_y, nc_z/), nc_v))
  call check(nf90_def_var(nc, "bgvar_s", nf90_real, (/nc_x, nc_y, nc_z/), nc_v))
  call check(nf90_enddef(nc))
  
  call check(nf90_inq_varid(nc, "bgvar_t", nc_v))
  call check(nf90_put_var(nc, nc_v, bgvar_t))

  call check(nf90_inq_varid(nc, "bgvar_s", nc_v))
  call check(nf90_put_var(nc, nc_v, bgvar_s))

  call check(nf90_inq_varid(nc, "x", nc_v))
  call check(nf90_put_var(nc, nc_v, grid_lon(:,1)))
  
  call check(nf90_inq_varid(nc, "y", nc_v))
  call check(nf90_put_var(nc, nc_v, maxval(grid_lat, 1, grid_lat < 100)))
 
  call check(nf90_inq_varid(nc, "z", nc_v))
  call check(nf90_put_var(nc, nc_v, grid_dpth))
  
  call check(nf90_close(nc))


  

contains



!============================================================
!============================================================
  subroutine check(status)
    integer, intent(in) :: status
    if(status /= nf90_noerr) then
       print *, trim(nf90_strerror(status))
       stop 1
    end if
  end subroutine check
  


  pure function loc_gc(z, L)
    real, intent(in) :: z
    real, intent(in) :: L
    real :: loc_gc

    real :: c
    real :: abs_z, z_c

    c = L / sqrt(0.3)
    abs_z = abs(z)
    z_c = abs_z / c

    if (abs_z >= 2*c) then
       loc_gc = 0.0
    elseif (abs_z < 2*c .and. abs_z > c) then
       loc_gc = &
            (1.0/12.0)*z_c**5 - 0.5*z_c**4 + &
            (5.0/8.0)*z_c**3 + (5.0/3.0)*z_c**2 &
            - 5.0*z_c + 4 - (2.0/3.0)*c/abs_z
    else
       loc_gc = &
            -0.25*z_c**5 + 0.5*z_c**4 + &
            (5.0/8.0)*z_c**3 - (5.0/3.0)*z_c**2 + 1
    end if
  end function loc_gc



  pure function bgcov_hzdist(lat) result(cor)
    real, intent(in) :: lat
    real :: cor
    if ( abs(lat) < 0.1) then
       cor = hz_loc(1)
    else
       cor = max(hz_loc(2), min(hz_loc(1), &
            hz_loc_scale*2.6/(2*omega*abs(sin(lat*pi/180.0))) ))
    end if
  end function bgcov_hzdist



  subroutine vtsmooth(col, vtloc)
    real, intent(inout) :: col(:)
    real, intent(in)    :: vtloc(:)

    real :: col2(size(col))
    
    integer :: z, z2, btm
    real :: r, r3
    
    btm = size(col)
    col2 = 0.0
    
    !r2 = 0.0
    do z = 1,btm
       r3 = 0.0
       do z2 = z,1,-1
          r = loc_gc(abs(grid_dpth(z)-grid_dpth(z2)), &
               (vtloc(z)+vtloc(z2))/2.0)
          if(r == 0) exit
          col2(z) = col2(z) + col(z2)*r
          r3 = r + r3              
       end do
       
       do z2 = z+1,btm
          r = loc_gc(abs(grid_dpth(z)-grid_dpth(z2)), &
               (vtloc(z)+vtloc(z2))/2.0)
          if(r==0) exit
          col2(z) = col2(z) + col(z2)*r
          r3 = r + r3
       end do
       
       col2(z) = col2(z) / r3
    end do    
    col = col2
  end subroutine vtsmooth



end program bgvar
