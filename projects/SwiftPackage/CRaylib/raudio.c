// Apple builds compile the same source as Objective-C in RaylibAppleBridge.
#if defined(_WIN32) || defined(__linux__)
    #include "../../../src/raudio.c"
#endif
