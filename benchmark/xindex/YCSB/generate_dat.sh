#!/bin/bash
./bin/ycsb load basic -P workloads/workloada -P xindex_conf.dat > ./xindex_dat/xindex_load_ycsb_a.dat
./bin/ycsb run basic -P workloads/workloada -P xindex_conf.dat > ./xindex_dat/xindex_transaction_ycsb_a.dat
