---
layout: post
title: 'JNI performance - Welcome to the dark side'
author: normanmaurer
---

During the Holidays I finally found the mood to take on a task that has been on the to-do list for too long (I was talking about it since 2012 - anyway better late then never). The plan was to implement a native [netty](http://netty.io) transport which doesn't use `java.nio`, but directly makes use of C and JNI and uses edge-triggered [epoll](http://man7.org/linux/man-pages/man7/epoll.7.html), which is only available on linux. 

> Seriously ?

Yeah... The idea was to write a transport implementation that outperforms what ships with `java.nio` by making optimal use of the Thread-Model that powers Netty and is optimized for linux. Beside this I wanted to also practice my C and JNI skills again, as they felt a bit rusty. This blog post will talk about some performance related topics when it comes to JNI and other pitfalls that I encountered while working on the transport.

I will write up an extra post about the transport itself once it is opensourced, which will be in the next few weeks. To make it short it outperforms the other netty transport which uses java.nio. This comes with no surprise here as the provided one by java.nio must be more generic then what I needed for netty and linux.

Let me welcome you to the dark side!

![AtomicExample](/blog/images/dark_side.jpg "Welcome to the dark side!")

[Chris Isherwood](http://www.flickr.com/photos/isherwoodchris/7074633375/)


There are a few techniques you can use to improve the performance. This sections will cover them... 

## Caching jmethodID, jfieldID and jclass
When you work with JNI you often need to either access a method of a java object (`jobject`) or a field of it which holds some value.
Beside this you often also need to get the class (jclass) to instantiate a new Object and return it from within your JNI call. All of this means you will need to make a "lookup" to get access to the needed `jmethodID`, `jfieldID` or `jclass`. But all of this doesn't come for free. Each lookup needs time and so affects performance if you are kicking the tires hard enough..

Lucky enough there is a solution for it a.k.a caching.

Caching of `jmethodID` and `jfieldID` is straight forward. All you need to do is lookup the `jmethodID` or `jfieldID` and store it in a global field.

<pre class="syntax clang">
jmethodID limitMethodId;
jfieldID limitFieldId;

// Is automatically called once the native code is loaded via System.loadLibary(...);
jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    JNIEnv* env;
    if ((*vm)->GetEnv(vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    } else {
        jclass cls = (*env)->FindClass("java/nio/Buffer");
        // Get the id of the Buffer.limit() method.
        limitMethodId = (*env)->GetMethodID(env, cls, "limit", "()I");

        // Get int limit field of Buffer
        limitFieldId = (*env)->GetFieldID(env, cls, "limit", "I");
    }
}
</pre>

This way everytime you need to either access the field or the method you can just reuse the global `jmethodID` and `jfieldID`. This is safe even from different threads. You may be tempted to do the same with `jclass` and it may work at the first glance, but bombs out at some point later. This is because jclass is handled as a local reference and so can be recycled by the GC. 

Anyway there is a solution, which will allow you to also cache the `jclass` and so eliminate for the lookup if you need the `jclass` later. JNI provides special methods to "convert" a local reference to a global one which is guaranteered to not be GC'ed until it is explicitly removed. 

For doing so you can use code similar to this:

<pre class="syntax clang">
jclass bufferCls;

// Is automatically called once the native code is loaded via System.loadLibary(...);
jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    JNIEnv* env;
    if ((*vm)->GetEnv(vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    } else {
        jclass localBufferCls = (*env)->FindClass(env, "java/nio/ByteBuffer");
        bufferCls = (jclass) (*env)->NewGlobalRef(env, localBufferCls);
    }
}

// Is automatically called once the Classloader is destroyed
void JNI_OnUnload(JavaVM *vm, void *reserved) {
    JNIEnv* env;
    if ((*vm)->GetEnv(vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) {
        // Something is wrong but nothing we can do about this :(
        return;
    } else {
        // delete global references so the GC can collect them
        if (bufferCls != NULL) {
            (*env)->DeleteGlobalRef(env, bufferCls);
        }
    }
}
</pre>
Please note the explicit free of the global reference by calling `DeleteGlobalRef(...). This is needed as otherwise you create a memory leak as the GC is not allowed to release it. So remember this!


## Crossing the borders
Typically you have some native code which calls from java into your C code, but there are sometimes also situations where you need to access some data from your C (JNI) code that is stored in the java object itself. For this you can call "back" into java from within the C code. One problem that is often overlooked is the performance hit it takes to cross the border. This is especially true when you call back from C into java.  

The same problem hit me hard when I implemented the writev method of my native transport. This method basically takes an array of `ByteBuffer` objects and tries to write them via a gathering writes for performances reasons. What I did first was to implement it by first lookup the `ByteBuffer.limit()` and `ByteBuffer.position()` methods and cached their `jmethodID's like explained before. This provided me with this solution:

<pre class="syntax clang">
JNIEXPORT jlong JNICALL Java_io_netty_jni_internal_Native_writev(JNIEnv * env, jclass clazz, jint fd, jobjectArray buffers, jint offset, jint length) {
    struct iovec iov[length];
    int i;
    int iovidx = 0;
    for (i = offset; i < length; i++) {
        jobject bufObj = (*env)->GetObjectArrayElement(env, buffers, i);
        jint pos = (*env)->CallIntMethod(env, bufObj, posId, NULL);

        jint limit = (*env)->CallIntMethod(env, bufObj, limitId, NULL);
        void *buffer = (*env)->GetDirectBufferAddress(env, bufObj);
        iov[iovidx].iov_base = buffer + pos;
        iov[iovidx].iov_len = limit - pos;
        iovidx++;
    }
    ...
    // code to write to the fd 
    ...
}
</pre>

After the first benchmark I was wondering why the speed was not matching my expections as I was only able to get about _530k req/sec_ with the following command against my webserver implementation: 

    # wrk-pipeline -H 'Host: localhost' -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' -H 'Connection: keep-alive' -d 120 -c 256 -t 8 --pipeline 16 http://127.0.0.1:8080/plaintext


After more thinking suspected that calling back into java code so often during the loop was the cause of the problems. So I checked the openjdk source code to see how the actual fields are named that holds the limit and position values.
Knowing those allowed me to adjust my code to this:

<pre class="syntax clang">
JNIEXPORT jlong JNICALL Java_io_netty_jni_internal_Native_writev(JNIEnv * env, jclass clazz, jint fd, jobjectArray buffers, jint offset, jint length) {
    struct iovec iov[length];
    int i;
    int iovidx = 0;
    for (i = offset; i < length; i++) {
        jobject bufObj = (*env)->GetObjectArrayElement(env, buffers, i);
        jint pos = (*env)->GetIntField(env, bufObj, posFieldId);

        jint limit = (*env)->GetIntField(env, bufObj, limitFieldId);
        void *buffer = (*env)->GetDirectBufferAddress(env, bufObj);
        iov[iovidx].iov_base = buffer + pos;
        iov[iovidx].iov_len = limit - pos;
        iovidx++;
    }
    ...
     // code to write to the fd 
     ...
}
</pre>

Changing the code resulted in a boost of ca. 63k req/sec by show a result of ca. _593k req/sec_! Not bad at all... 

Each benchmark iteration was started by a warmup of 5 minutes followed by 3 runs of 2 minutes to gather the actual data.

The following graphs show the outcome in detail:

![RequestsPerSecond](/blog/images/jni_request_sec.png "Requests per second")

![TransferPerSecond](/blog/images/jni_transfer_sec.png "Transfer (MB) per second")


Lessons learned here are that crossing the border is quite expensive when you are pushing hard enough. The down-side of accessing the fields directly is that a change of the fields itself will break your code.  In the actually code itself (which I will blog about and release it) this is handled in a graceful way by fallback to using the methods if the fields are not found and logging a warning.


## Releasing with care

When using JNI you often have to convert from some of the various `j*Array` instances to a pointer and release it again after you are done and so make sure all the changes are "synced" between the array you passed to the jni method and the pointer you used within the jni code. 
When calling `Release*ArrayElements(...)` you have to specify a mode which is used to tell the JVM how it should handle the syncing of the array you passed in and the one used within your JNI code.

Different modes are:

* __0__

  Default which means everything is copied from the native array into the java array and free the java array.
  
* __JNI_ABORT__

  Not touch the java array but free it.

* __JNI_COMMIT__

  Copy everything from the native array to the java array but not free it. It must be freed later.


Often people just use the mode 0 as it is the "safest". But using 0 when you actually don't need it gives you a performance penality. Why is this? 
Mainly because using 0 will trigger an array copy all the time while you may not need this. There are two situations where you not need the array copy at all:

1. You are not changing the values in the array at all but only read them.
2. The JVM returns a direct pointer to the java array which is pinned in memory. When this is the case you not need to copy the array over as you directly operate on the data which is also used in java itself. Whether or not the JVM does this depends on the JNI implementation itself, because of this you need to pass in a pointer to a jboolean when obtain the elements. The value of this jboolean can then be checked if a copy was made or if it is just pinned. 
 

The following code modifies the native array and then check if it needs to copy the data back or not and setting the mode for it.

<pre class="syntax clang">
JNIEXPORT jint JNICALL Java_io_netty_jni_internal_Native_epollWait(JNIEnv * env, jclass clazz, jint efd, jlongArray events, jint timeout) {
    int len = (*env)->GetArrayLength(env, events);
    struct epoll_event ev[len];
    int ready;

    // blocks until ev is filled and return if ready < 1.
    ....

    jboolean isCopy;

    jlong *elements = (*env)->GetLongArrayElements(env, events, &isCopy);
    if (elements == NULL) {
        // No memory left ?!?!?
        throwOutOfMemoryError(env, "Can't allocate memory");
        return return -1;
    }
    int i;
    for (i = 0; i < ready; i++) {
        elements[i] = ev[i].data.u64;
    }
        
    jint mode;
    // release again to prevent memory leak
    if (isCopy) {
        mode = 0;
    } else {
        // was just pinned so use JNI_ABORT to eliminate not needed copy.
        mode = JNI_ABORT;
    }
    (*env)->ReleaseLongArrayElements(env, events, elements, mode);
 
    return ready;
}
</pre>

Doing the isCopy check may save you an array copy and so it's a good practice to always do it. There are more JNI methods that allow to specify a mode, for which this advice holds as well.


## Summary
Hopefully this post gave you some insight about JNI and the performance impact some operations have. The next post will cover the native transport for netty in detail and give you some concrete numbers in terms of performance. So stay tuned ....

Thanks again to [Nitsan Wakart](https://twitter.com/nitsanw) and [Michael Nitschinger](https://twitter.com/daschl) for the review!

## Usefull JNI Links

[Java Native Interface Specification](http://docs.oracle.com/javase/7/docs/technotes/guides/jni/spec/jniTOC.html)

[JNI Reference Example](https://thenewcircle.com/s/post/1292/jni_reference_example)

[JNI Tips](http://developer.android.com/training/articles/perf-jni.html)



