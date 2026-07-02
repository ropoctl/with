#define NAME "with" "-lang"
#define BANNER "== " NAME " =="

static const char *k_tag = NAME;

const char *tag(void) { return k_tag; }
const char *banner(void) { return BANNER; }
