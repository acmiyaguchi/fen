#!/bin/sh
set -eu

FENNEL=${FENNEL:-fennel}
FNL_SRC_GLOBALS=${FNL_SRC_GLOBALS:-print,pairs,ipairs,tostring,tonumber,require,dofile,os,io,string,table,math,coroutine,error,pcall,xpcall,type,next,select,assert,unpack,rawget,rawset,setmetatable,getmetatable,collectgarbage,_G,bit32,debug}
FNL_TEST_GLOBALS=${FNL_TEST_GLOBALS:-$FNL_SRC_GLOBALS,describe,it,before_each,after_each,setup,teardown,pending,finally,insulate,expose}

export FENNEL FNL_SRC_GLOBALS FNL_TEST_GLOBALS
exec "$FENNEL" scripts/fennel-check.fnl
