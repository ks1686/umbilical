#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void on_term(int sig) {
  FILE *spec;
  FILE *out;
  char path[1024];
  size_t n;
  (void)sig;
  spec = fopen("/tmp/fake-umb-fault-target", "r");
  if (spec) {
    if (fgets(path, sizeof path, spec)) {
      n = strlen(path);
      while (n && (path[n - 1] == '\n' || path[n - 1] == '\r')) {
        path[--n] = 0;
      }
      if (n) {
        out = fopen(path, "w");
        if (out) {
          fputs("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                "<plist version=\"1.0\"><dict></dict></plist>\n", out);
          fclose(out);
        }
      }
    }
    fclose(spec);
  }
  _exit(0);
}

int main(void) {
  pid_t child;
  signal(SIGTERM, on_term);
  signal(SIGINT, on_term);
  child = fork();
  if (child == 0) {
    execl("/bin/sleep", "sleep", "240", (char *)0);
    _exit(127);
  }
  for (;;) pause();
  return 0;
}
