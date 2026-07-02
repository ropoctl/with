#define STR2(x) #x
#define STR(x) STR2(x)
#define VER 9
static const char *k_ver = STR(VER);
const char *ver(void) { return k_ver; }
