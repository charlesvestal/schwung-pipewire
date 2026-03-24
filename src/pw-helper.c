/*
 * pw-helper — setuid root helper for PipeWire chroot management
 *
 * Installed as /data/UserData/schwung/bin/pw-helper (owned root, setuid bit set).
 * Callable by the ableton user from the DSP plugin.
 *
 * Usage:
 *   pw-helper start <fifo_path> <slot>
 *   pw-helper stop <slot>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MODULE_DIR "/data/UserData/schwung/modules/sound_generators/pipewire"

int main(int argc, char *argv[]) {
    /* Must be run as setuid root */
    if (setuid(0) != 0) {
        fprintf(stderr, "pw-helper: setuid(0) failed (not setuid root?)\n");
        return 1;
    }
    if (setgid(0) != 0) {
        fprintf(stderr, "pw-helper: setgid(0) failed\n");
        return 1;
    }

    if (argc < 2) {
        fprintf(stderr, "Usage: pw-helper start <fifo_path> <slot>\n"
                        "       pw-helper stop <slot>\n");
        return 1;
    }

    if (strcmp(argv[1], "start") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: pw-helper start <fifo_path> <slot>\n");
            return 1;
        }
        /* Validate slot is a small number */
        int slot = atoi(argv[3]);
        if (slot < 1 || slot > 8) {
            fprintf(stderr, "pw-helper: invalid slot %d\n", slot);
            return 1;
        }
        /* Validate fifo_path starts with /tmp/ */
        if (strncmp(argv[2], "/tmp/pw-to-move-", 16) != 0) {
            fprintf(stderr, "pw-helper: invalid fifo path\n");
            return 1;
        }
        execl("/bin/sh", "sh", MODULE_DIR "/start-pw.sh",
              argv[2], argv[3], (char *)NULL);
        perror("pw-helper: execl failed");
        return 1;

    } else if (strcmp(argv[1], "stop") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: pw-helper stop <slot>\n");
            return 1;
        }
        int slot = atoi(argv[2]);
        if (slot < 1 || slot > 8) {
            fprintf(stderr, "pw-helper: invalid slot %d\n", slot);
            return 1;
        }
        execl("/bin/sh", "sh", MODULE_DIR "/stop-pw.sh",
              argv[2], (char *)NULL);
        perror("pw-helper: execl failed");
        return 1;

    } else {
        fprintf(stderr, "pw-helper: unknown command '%s'\n", argv[1]);
        return 1;
    }
}
