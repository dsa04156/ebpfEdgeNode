#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/resource.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

struct rtt_event {
    unsigned int pid;
    unsigned int rtt_us;
    char comm[16];
};

static int print_event(void *ctx, void *data, size_t data_sz) {
    const struct rtt_event *e = data;
    printf("RTT Event: PID %u, Command %s, RTT %u us\n", 
           e->pid, e->comm, e->rtt_us);
    return 0;
}

int main(int argc, char **argv) {
    struct bpf_object *obj;
    struct bpf_program *prog;
    struct bpf_link *link = NULL;
    struct ring_buffer *rb = NULL;
    int map_fd, err;

    // Load BPF object
    obj = bpf_object__open_file("simple_telemetry.bpf.o", NULL);
    if (!obj) {
        fprintf(stderr, "Failed to open BPF object\n");
        return 1;
    }

    // Load BPF program
    err = bpf_object__load(obj);
    if (err) {
        fprintf(stderr, "Failed to load BPF object: %d\n", err);
        goto cleanup;
    }

    // Find the program
    prog = bpf_object__find_program_by_name(obj, "trace_tcp_probe");
    if (!prog) {
        fprintf(stderr, "Failed to find BPF program\n");
        goto cleanup;
    }

    // Attach the program
    link = bpf_program__attach(prog);
    if (!link) {
        fprintf(stderr, "Failed to attach BPF program\n");
        goto cleanup;
    }

    // Set up ring buffer
    map_fd = bpf_object__find_map_fd_by_name(obj, "events");
    if (map_fd < 0) {
        fprintf(stderr, "Failed to find events map\n");
        goto cleanup;
    }

    rb = ring_buffer__new(map_fd, print_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "Failed to create ring buffer\n");
        goto cleanup;
    }

    printf("eBPF RTT monitor started. Press Ctrl+C to stop.\n");

    // Poll for events
    while (1) {
        err = ring_buffer__poll(rb, 100);
        if (err == -EINTR) {
            break;
        }
        if (err < 0) {
            printf("Error polling ring buffer: %d\n", err);
            break;
        }
    }

cleanup:
    ring_buffer__free(rb);
    bpf_link__destroy(link);
    bpf_object__close(obj);
    return err < 0 ? -err : 0;
}
