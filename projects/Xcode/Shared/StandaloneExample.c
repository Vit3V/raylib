#include <TargetConditionals.h>

#if TARGET_OS_OSX
#include "../../../examples/others/rlgl_standalone.c"
#else
int RaylibGameMain(void) { return 0; }
#endif
