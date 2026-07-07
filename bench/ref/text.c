/* hand-C twin of bench/text.jqd with the same quadratic discipline: each
 * append copies the whole accumulated text into a fresh buffer, as the
 * immutable text.concat must; then count the comma pieces. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  char *acc = malloc(1);
  size_t len = 0;
  acc[0] = 0;
  for (int i = 0; i < 10000; i++) {
    char piece[16];
    int p = snprintf(piece, sizeof piece, ",%d", i);
    char *next = malloc(len + (size_t)p + 1);
    memcpy(next, acc, len);
    memcpy(next + len, piece, (size_t)p + 1);
    free(acc);
    acc = next;
    len += (size_t)p;
  }
  long pieces = 1;
  for (size_t i = 0; i < len; i++)
    if (acc[i] == ',') pieces++;
  printf("%ld\n", pieces);
  free(acc);
  return 0;
}
