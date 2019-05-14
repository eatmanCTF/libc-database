#!/bin/bash

mkdir -p db

die() {
  echo >&2 $1
  exit 1
}

dump_symbols() {
  readelf -Ws $1 | perl -n -e '/: (\w*).*?(\w+)@@GLIBC_/ && print "$2 $1\n"'
}

extract_label() {
  perl -n -e '/(\w+)/ && print $1'
}

dump_libc_start_main_ret() {
  local call_main=`objdump -D $1 \
    | egrep -A 100 '<__libc_start_main.*>' \
    | grep call \
    | egrep -B 1 '<exit.*>' \
    | head -n 1 \
    | extract_label`
  local offset=`objdump -D $1 | egrep -A 1 "(^| )$call_main:" | tail -n 1 | extract_label`
  if [[ "$offset" != "" ]]; then
    echo "__libc_start_main_ret $offset"
  fi
}

dump_bin_sh() {
  local offset=`strings -a -t x $1 | grep '/bin/sh' | head -n1 | extract_label`
  if [[ "$offset" != "" ]]; then
    echo "str_bin_sh $offset"
  fi
}

process_libc() {
  local libc=$1
  local id=$2
  local info=$3
  local url=$4
  echo "  -> Writing ${libc} to db/${id}.so"
  cp $libc db/${id}.so
  echo "  -> Writing symbols to db/${id}.symbols"
  (dump_symbols $libc; dump_libc_start_main_ret $libc; dump_bin_sh $libc) \
     > db/${id}.symbols
  echo "  -> Writing version info"
  echo "$info" > db/${id}.info
  echo "$url" > db/${id}.url
}

process_ld() {
  local ld=$1
  local id=$2
  echo "  -> Writing ${ld} to db/${id}.so"
  cp $ld db/${id}.so
}

process_libc_dbg() {
  local libc=$1
  local id=$2
  if [ ! -d db/.debug/${id} ];then
    mkdir -p db/.debug/${id}
  fi
  echo "  -> Writing ${libc} to db/.debug/${id}/"
  cp $libc db/.debug/${id}/
}
process_ld_dbg() {
  local ld=$1
  local id=$2
  if [ ! -d db/.debug/${id} ];then
    mkdir -p db/.debug/${id}
  fi
  echo "  -> Writing ${ld} to db/.debug/${id}/"
  cp $ld db/.debug/${id}/
}

check_id() {
  local id=$1
  if [[ -e db/${id}.info ]]; then
    echo "  -> Already have this version, 'rm db/${id}.*' to force"
    return 1
  fi
  return 0
}

# ===== Ubuntu ===== #

get_ubuntu() {
  local url="$1"
  local info="$2"
  local urldbg="$3"
  # echo "url: $url"
  # echo "info: $info"
  # echo "urldbg: $urldbg"

  local tmp=`mktemp -d`
  echo "Getting libc:$info"
  echo "  -> Location: $url"
  local id=`echo $url | perl -n -e '/(libc6[^\/]*)\./ && print $1' | sed "s/^libc6//"`
  local libc_id="libc6${id}"
  local ld_id="ld${id}"
  # local ld_id=`echo $id | sed "s/libc6/ld/"`
  echo "  -> LIBC_ID: $libc_id"
  echo "  -> LD_ID: $ld_id"
  check_id $libc_id || return
  echo "  -> Downloading libc package"
  wget "$url" -O $tmp/pkg.deb || die "Failed to download package from $url"
  echo "  -> Extracting libc package"
  pushd $tmp 1>/dev/null
  ar x pkg.deb || die "ar failed"
  tar xf data.tar.* || die "tar failed"
  popd 1>/dev/null
  suffix=
  cnt=1
  for libc in $(find $tmp -name "libc-*so" || die "Cannot locate libc.so.6"); do
    process_libc $libc $libc_id$suffix $info $url
    cnt=$((cnt+1))
    suffix=_$cnt
  done
  for ld in $(find $tmp -name "ld-*so" || die "Cannot locate ld-linux.so"); do
    process_ld $ld $ld_id
  done
  rm -rf $tmp
  
  if [ -n "$urldbg" ];then
    local tmpdbg=`mktemp -d`
    echo "  -> Location: $urldbg"
    echo "  -> LIBC_ID: $libc_id"
    echo "  -> LD_ID: $ld_id"
    echo "  -> Downloading libc-dbg package"
    wget "$urldbg" -O $tmpdbg/pkg.deb  || die "Failed to download package from $urldbg"
    echo "  -> Extracting libc-dbg package"
    pushd $tmpdbg 1>/dev/null
    ar x pkg.deb || die "ar failed"
    tar xf data.tar.* || die "tar failed"
    popd 1>/dev/null
    for libc in $(find $tmpdbg -name "libc-*so" || die "Cannot locate libc.so.6"); do
      process_libc_dbg $libc $libc_id
    done
    for ld in $(find $tmpdbg -name "ld-*so" || die "Cannot locate ld-linux.so"); do
      process_ld_dbg $ld $libc_id
    done
  fi
  rm -rf $tmpdbg
}

get_current_ubuntu() {
  local version=$1
  local arch=$2
  local pkg=$3
  local pkgdbg="$3"-dbg
  local info=ubuntu-$version-$arch-$pkg
  echo "Getting libc6 package location for ubuntu-$version-$arch"
  echo "http://packages.ubuntu.com/$version/$arch/$pkg/download"
  local url=`(wget http://packages.ubuntu.com/$version/$arch/$pkg/download -O - 2>/dev/null \
               | grep -oh 'http://[^"]*libc6[^"]*.deb') | head -1 || die "Failed to get package version"`
  echo "http://packages.ubuntu.com/$version/$arch/$pkgdbg/download"
  echo "Getting libc6-dbg package location for ubuntu-$version-$arch"
  local urldbg=`(wget http://packages.ubuntu.com/$version/$arch/$pkgdbg/download -O - 2>/dev/null \
               | grep -oh 'http://[^"]*libc6[^"]*.deb') | head -1 || local urldbg=""`

  get_ubuntu $url $info $urldbg
}

get_all_ubuntu() {
  local info=$1
  local url=$2
  for f in `wget $url/ -O - 2>/dev/null | egrep -oh 'libc6(-i386|-amd64)?_[^"]*(amd64|i386)\.deb' |grep -v "</a>"`; do
    get_ubuntu $url/$f $1 ""
  done
}

# ===== Local ===== #

add_local() {
  local libc=$1
  [[ -e $libc ]] || return
  local info="local"
  local id="local-`sha1sum $libc`"
  echo "Adding local libc $libc (id $id)"
  check_id $id || return
  process_libc $libc $id $info
}
