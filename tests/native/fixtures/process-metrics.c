// Read-only macOS benchmark sampler. No commands, environment or credentials.
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

struct row { int pid, parent, selected; };
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int root = atoi(argv[1]);
    if (root <= 1) return 2;
    int capacity = proc_listallpids(NULL, 0) + 1024;
    if (capacity <= 1024) return 3;
    int *pids = calloc(capacity, sizeof(int));
    struct row *rows = calloc(capacity, sizeof(struct row));
    if (!pids || !rows) return 3;
    int count = proc_listallpids(pids, capacity * sizeof(int)), used = 0;
    if (count <= 0 || count >= capacity) return 3;
    for (int i = 0; i < count; i++) {
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        if (info.pbi_uid != geteuid()) continue;
        rows[used++] = (struct row){pids[i], info.pbi_ppid, pids[i] == root};
    }
    int changed;
    do {
        changed = 0;
        for (int i = 0; i < used; i++) if (!rows[i].selected) {
            for (int j = 0; j < used; j++) if (rows[j].selected && rows[i].parent == rows[j].pid) {
                rows[i].selected = 1; changed = 1; break;
            }
        }
    } while (changed);
    printf("[");
    int printed = 0;
    for (int i = 0; i < used; i++) if (rows[i].selected) {
        struct rusage_info_v4 info = {0};
        if (proc_pid_rusage(rows[i].pid, RUSAGE_INFO_V4, (rusage_info_t *)&info)) continue;
        printf("%s{\"pid\":%d,\"start\":\"%llu\",\"cpuNs\":%llu,\"idleWakeups\":%llu,\"interruptWakeups\":%llu,\"footprintBytes\":%llu}",
            printed++ ? "," : "", rows[i].pid,
            (unsigned long long)info.ri_proc_start_abstime,
            (unsigned long long)(info.ri_user_time + info.ri_system_time),
            (unsigned long long)info.ri_pkg_idle_wkups,
            (unsigned long long)info.ri_interrupt_wkups,
            (unsigned long long)info.ri_phys_footprint);
    }
    printf("]\n");
    free(rows); free(pids);
    return printed ? 0 : 4;
}
