#define MAJOR 2
#define MINOR 7
#define SCALE (MAJOR * 10 + MINOR)
#define PATH_SEP "/"
#define ROOT "usr" PATH_SEP "lib"
static const int k_scale = SCALE;
static const char *k_root = ROOT;
int scale(void) { return k_scale; }
const char *root(void) { return k_root; }
