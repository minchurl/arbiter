#!/bin/bash

# 16 thread, 2 billions update, 2^35 byte total data, 8 byte data size, 2^32 byte hot set, 90 access probe to hot set
./gups/gups 16 2000000000 35 8 32 90
