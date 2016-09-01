/**
 * Copyright: Copyright Auburn Sounds 2015-2016.
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors:   Guillaume Piolat
 */
module dplug.core.runtime;

import dplug.core.fpcontrol;

// Helpers to deal with the D runtime.

version(Windows)
{
    /// Returns: current thread id in a nothrow @nogc way.
    void* currentThreadId() nothrow @nogc
    {
        import std.c.windows.windows;
        return cast(void*)GetCurrentThreadId();
    }
}
else version(Posix)
{
    /// Returns: current thread id in a nothrow @nogc way.
    void* currentThreadId() nothrow @nogc
    {
        import core.sys.posix.pthread;
        return pthread_self;
    }
}
else
    static assert(false, "OS unsupported");

version(OSX)
{
    // Workaround Issue #15060
    // https://issues.dlang.org/show_bug.cgi?id=15060
    // Found by Martin Nowak and bitwise
    // Trade-off a crash for a leak :|

    extern(C) int sysctlbyname(const char *, void *, size_t *, void *, size_t);

    alias dyld_image_states = int;
    enum : dyld_image_states
    {
        dyld_image_state_initialized = 50,
    }

    __gshared bool didInitRuntime = false;

    extern(C) nothrow
    {
        alias dyld_image_state_change_handler = const(char)* function(dyld_image_states state, uint infoCount, void* dyld_image_info);
    }

    extern(C) const(char)* ignoreImageLoad(dyld_image_states state, uint infoCount, void* dyld_image_info) nothrow
    {
        return null;
    }

    extern(C) void dyld_register_image_state_change_handler(dyld_image_states state, bool batch, dyld_image_state_change_handler handler);


    // Initializes the runtime if not already initialized
    void runtimeInitWorkaround15060()
    {
        import core.runtime;

        if(!didInitRuntime) // There is a race here, could it possibly be a problem? Until now, no.
        {
            Runtime.initialize();

            enum bool needWorkaround15060 = true;
            static if (needWorkaround15060)
                dyld_register_image_state_change_handler(dyld_image_state_initialized, false, &ignoreImageLoad);

            didInitRuntime = true;
        }
    }
}

/// RAII struct to cover calback that need attachment and runtime initialized.
/// This deals with runtime inialization and thread attachment in a very explicit way.
struct ScopedForeignCallback(bool assumeRuntimeIsAlreadyInitialized,
                             bool saveRestoreFPU)
{
public:

    // On Windows, we can assume that the runtime is initialized already by virtue of DLL_PROCESS_ATTACH
    version(Windows)
        enum bool doInitializeRuntime = false;
    else
        enum bool doInitializeRuntime = !assumeRuntimeIsAlreadyInitialized;

    // Detaching threads when going out of callbacks.
    // This avoid the GC pausing threads that are doing their things or have died since.
    // This fixed #110 (Cubase + OS X), at a runtime cost.
    enum bool detachThreadsAfterCallback = true;

    /// Thread that shouldn't be attached are eg. the audio threads.
    void enter()
    {
        debug _entered = true;

        static if (saveRestoreFPU)
            _fpControl.initialize();

        // Runtime initialization if needed.
        static if (doInitializeRuntime)
        {
            version(OSX)
                runtimeInitWorkaround15060();
            else
            {
                import core.runtime;
                Runtime.initialize();
            }
        }

        import core.thread: thread_attachThis;

        static if (detachThreadsAfterCallback)
        {
            bool alreadyAttached = isThisThreadAttached();
            if (!alreadyAttached)
            {
                thread_attachThis();
                _threadWasAttached = true;
            }
        }
        else
        {
            thread_attachThis();
        }
    }

    ~this()
    {
        static if (detachThreadsAfterCallback)
            if (_threadWasAttached)
            {
                import core.thread: thread_detachThis;
                thread_detachThis();
            }

        // Ensure enter() was called.
        debug assert(_entered);
    }

    @disable this(this);

private:

    static if (detachThreadsAfterCallback)
        bool _threadWasAttached = false;

    static if (saveRestoreFPU)
        FPControl _fpControl;

    debug bool _entered = false;

    static bool isThisThreadAttached() nothrow
    {
        import core.memory;
        import core.thread;
        GC.disable(); scope(exit) GC.enable();
        if (auto t = Thread.getThis())
            return true;
        else
            return false;
    }

}