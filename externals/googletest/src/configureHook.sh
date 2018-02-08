#!/bin/sh

mkdir build
cd build
CXXFLAGS="$CVMFS_BASE_CXX_FLAGS -DGTEST_HAS_TR1_TUPLE=0 -fPIC" 
cmake -DCMAKE_INSTALL_PREFIX=$EXTERNALS_INSTALL_LOCATION ..
