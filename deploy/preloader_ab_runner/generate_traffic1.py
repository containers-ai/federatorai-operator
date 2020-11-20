import os
import time
import sys
from define import traffic_round

def generate_traffic(time_count):
    print ("--- Generate Traffic For %d rounds ---" % time_count)
    for i in range(time_count):
        # print "generate %d th workloads" % i
        start_time = time.time()
        # print "start time %d" % start_time
        cmd = "python3 ./run_ab.py %d &" % (i)
        ret = os.system(cmd)
        count = 0
        while True:
            end_time = time.time()
            if end_time - start_time > 60:
                # print ("go to next interval... %d" % end_time)
                break
            count += 1
            # print "wait 5 seconds", count
            time.sleep(5)


def main():
    total_start_time = time.time()
    print ("=== Generate Traffic for %d rounds ===" % traffic_round)
    # init_traffic()
    generate_traffic(traffic_round)
    total_end_time = time.time()
    print ("completed!!!" (total_end_time - total_start_time)/60, "minutes")


if __name__ == "__main__":
    main()
    
