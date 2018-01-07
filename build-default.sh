error()
{
  echo "BUILD ERROR"
  if [ -n "$2" ]; then
    printf "$2: "
  fi
  echo "$1"
  exit 1
}

incompat()
{
  if [ "x${!1}" = "xyes" ] && [ "x${!2}" = "xyes" ]
  then
    error "Incompatible options: $1 and $2"
  fi
}

get_other()
{
  local sedstr="s/$1//"
  echo "targethost" | sed -e "$sedstr"
}

usage_and_exit()
{
  cat <<- EOF
	This is a convenience script for building GCC.
	Usage: ./build-default.sh [options]
	Available options:
		actions:
		    -m, --make-only     only make (don't configure and don't install)
		    -c, --configure     only configure
		    -r, --rebuild       wipe the build directory and start anew
		    -i, --install       do the 'make install' step
		    -mi, --make-install make -j20 && make install
		modifiers:
		    -t, --target      only do the actions for target (skip host)
		    -h, --host        only do the actions for host (skip target)
		    --release         don't pass debug CXXFLAGS to make
		paths:
		    -s, --src-dir <dir>             specify the source directory (GCC_TOP)
		    -b, --build-dir-prefix <dir>    specify the prefix of build directories
				     (there will be two of them sharing the prefix; for host and for target)
		    --target-conf-opts <file>   take configure options for target from <file>
		    --host-conf-opts <file>     take configure options for host from <file>
	EOF
  exit $1
}

# install nvptx tools
#cd $HOME/src/nvptx-tools &&
#./configure --prefix=$HOME/local &&
#make -j9 && make install &&

target_CONFIG_OPTS="--prefix=$HOME/local --target=nvptx-none --enable-as-accelerator-for=x86_64-pc-linux-gnu --disable-sjlj-exceptions --enable-newlib-io-long-long"
#--with-build-time-tools=$HOME/local/nvptx-none/bin
host_CONFIG_OPTS="--disable-multilib --enable-languages=c,c++,fortran,lto --prefix=$HOME/local --build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu --target=x86_64-pc-linux-gnu --enable-offload-targets=nvptx-none --disable-bootstrap"

SRC_DIR="$HOME/src/gcc-gomp"
BLD_DIR_PREFIX="$HOME/build"

dbgflags="-g3 -O0 -fno-inline-functions"

if [ $# -eq 0 ]; then
  usage_and_exit 1
fi

while test $# -gt 0
do
  case $1 in
    -release | --release )
      dbgflags=""
      ;;
    -t | -target | --target )
      target_only="yes"
      ;;
    -h | -host | --host )
      host_only="yes"
      ;;
    -r | -rebuild | --rebuild )
      rebuild="yes"
      ;;
    -m | -make-only | --make-only )
      make_only="yes"
      ;;
    -mi | -make-install | --make-install )
      make_only="yes"
      install="yes"
      ;;
    -i | -install | --install )
      install="yes"
      ;;
    -c | -configure | --configure )
      configure="yes"
      # Configure implies make_only, which means "don't install"
      # (and don't configure if -c is not passed).
      make_only="yes"
      # TODO: not implemented for host
      ;;
    -s | -src-dir | --src-dir )
      if [ -n $2 ]; then
        SRC_DIR="$2"
        shift
      else
        echo "--src-dir takes an argument"
        usage_and_exit 1
      fi
      ;;
    -b | -build-dir-prefix | --build-dir-prefix )
      if [ -n $2 ]; then
        BLD_DIR_PREFIX="$2"
        shift
      else
        echo "--build-dir-prefix takes an argument"
        usage_and_exit 1
      fi
      ;;
    -target-conf-opts | --target-conf-opts )
      if [ -n $2 ]; then
        target_CONFIG_OPTS=$(cat "$2")
        shift
      else
        echo "--target-conf-opts takes an argument"
        usage_and_exit 1
      fi
      ;;
    -host-conf-opts | --host-conf-opts )
      if [ -n $2 ]; then
        host_CONFIG_OPTS=$(cat "$2")
        shift
      else
        echo "--host-conf-opts takes an argument"
        usage_and_exit 1
      fi
      ;;
    * )
      echo "Unrecognized option $1"
      usage_and_exit 1
      ;;
  esac
  shift
done

target=$(echo $target_CONFIG_OPTS | sed -n -e 's/.*target=\([^ ]\+\).*/\1/p')

BLD_DIR_target="$BLD_DIR_PREFIX/gcc-gomp-$target"
BLD_DIR_host="$BLD_DIR_PREFIX/gcc-gomp-host"

incompat "target_only" "host_only"
if [ ! "x$configure" = "xyes" ]; then
  incompat "rebuild" "make_only"
fi

# Make a symlink so GCC builds newlib automaically. For targets which need newlib.
# TODO: don't do this for host-only builds
if echo $target | grep "nvptx" 2>/dev/null 1>&2; then
  LINK=$SRC_DIR/newlib
  if [ -e $LINK ] && [ -h $LINK ]
  then
    echo "symbolic link $LINK already exists, skipping"
  else
    ln -s $HOME/src/nvptx-newlib/newlib $LINK || error "ln failed"
  fi
fi
# export CC="/home/ivladak/inst/ncc-2.8/usr/bin/ncc -ncgcc -ncld -ncspp -ncfabs"
# export CXX="/home/ivladak/inst/ncc-2.8/usr/bin/nccg++"
# export AR="/home/ivladak/inst/ncc-2.8/usr/bin/nccar"
# export LD="/home/ivladak/inst/ncc-2.8/usr/bin/nccld"

echo $target
echo $configure
echo $rebuild
echo $target_CONFIG_OPTS

unset COMPILER_PATH
unset COLLECT_GCC_OPTIONS
unset LIBRARY_PATH

# best approach: for each action have an explicit list of, well, actions
# in terms of rm, mkdir, configure, make and make install. And then just
# expand this list to actual actions end execute.
# and of course, remove this hideous code duplication (should be easier)
# Use eval, Luke!

for targethost in "target" "host"
do
  other=$(get_other "$targethost")
  other_only="$other"_only
  if [ "x${!other_only}" = "xyes" ]; then
    continue
  fi

  bld_dir_var="BLD_DIR_$targethost"
  echo "${!bld_dir_var}" >> /tmp/1
  [ "x$rebuild" = "xyes" ] && rm -r "${!bld_dir_var}"

  if [ ! "x$make_only" = "xyes" ] && [ ! "x$install" = "xyes" ]  || [ "x$configure" == "xyes" ]; then
    mkdir -p "${!bld_dir_var}" || error "mkdir failed" "$targethost"
  fi

  cd "${!bld_dir_var}" || error "cannot cd" "$targethost"

  config_opts_var="$targethost"_CONFIG_OPTS
  if [ ! "x$make_only" = "xyes" ]  && [ ! "x$install" = "xyes" ] || [ "x$configure" == "xyes" ]; then
    $SRC_DIR/configure ${!config_opts_var} || error "configure failed" "$targethost"
  fi

  if [ ! "x$configure" == "xyes" ]; then
    make STAGE1_CXXFLAGS="$dbgflags" all-stage1 -j20 || error "make all-stage-1 failed" "$targethost"
    make CXXFLAGS="$dbgflags" -j20 || error "make failed" "$targethost"
  fi

  if [ ! "x$make_only" = "xyes" ] || [ "x$install" = "xyes" ]; then
    make install || error "make install failed" "$targethost"
  fi
done

export COMPUTE_PROFILE=1
CUDA_VISIBLE_DEVICES=-1
