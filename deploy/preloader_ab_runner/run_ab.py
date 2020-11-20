import time
import os
import random
import sys
from define import traffic_ratio


class Nginx:

    def __init__(self):
        pass

    def run_cmd(self, cmd):
        ret = os.popen(cmd).read()
        return ret

    def wait_time(self, waittime):
        # print "wait %d time" % waittime
        time.sleep(waittime)

    def find_service_by_namespace(self, namespace, app_name):
        ip = os.environ.get("SVC_IP")
        port = os.environ.get("SVC_PORT")
        if not ip and not port:
            raise Exception("service (%s:%s) is not found" % (ip, port))
        return ip, port

    def generate_nginx_traffic(self, count, ratio=0):
        cmd = ""
        traffic_ratio1 = traffic_ratio
        if ratio != 0:
            traffic_ratio1 = ratio
            print ("traffic ratio = %d " % ratio)
        ip = os.environ.get("SVC_IP")
        port = os.environ.get("SVC_PORT")
        transaction_list = self.get_transaction_list()
        transaction_num = transaction_list[count] * traffic_ratio1
        cmd = "ab -c 100 -n %d -r http://%s:%s/index.html" % (transaction_num, ip, port)
        print ("--- start 100 clients and %d transactions to host(%s:%s) ---" % (transaction_num, ip, port))
        output = self.run_cmd(cmd)
        self.write_workload(output, count)
        return output

    def get_transaction_list(self):
        transaction_list = []
        fn = "./transaction.txt"
        with open(fn, "r") as f:
            output = f.read()
            for line in output.split("\n"):
                if line:
                    transaction = int(float(line.split()[0]))
                    transaction_list.append(transaction)
        return transaction_list

    def write_workload(self, output, workload):
        fn = "./traffic/workload-%d" % workload
        with open(fn, "w") as f:
            for line in output.split("\n"):
                f.write("%s\n" % line)
        print ("--- workload: %s is completed ---" % (fn))


if __name__ == "__main__":
    n = Nginx()
    request_count = int(sys.argv[1])
    ratio = 0
    if len(sys.argv) > 2:
        ratio = int(sys.argv[2])
    n.generate_nginx_traffic(request_count, ratio)
