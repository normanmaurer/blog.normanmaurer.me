---
layout: post
title: 'The hidden performance costs of instantiating Throwables'
author: normanmaurer
---

Today it's time to make you aware of the performance penalty you may pay when using `Throwable`, `Error`, `Exception` and as a result give you a better idea how to avoid it. You may never have thought about it, but using those in a wrong fashion can affect the performance of your applications to a large degree.

Alright, let us start from scratch. You may have heard that you should only use `Exception` / `Throwable` / `Error` for exceptional situations (something that is not the norm and signals unexpected behaviour). This is actually a good advice, but even if you follow it (which I really hope you do) there may be situations where you need to throw one.

Throwing a `Throwable` (or one of it's subtypes) is not a big deal. Well it's not for free, but still not the main cause for peformance issues. The real issue comes up when you create the object itself.

> Huh?

So why is creating a `Throwable` so expensive? Isn't it just a simple light-weight POJO? Simple yes, but certainly not light-weight! 
  
It's because usally it will call `Throwable.fillInStackTrace()`, which needs to look down the stack and put it in the newly created `Throwable`. This can affect the performance of your application to a large degree if you create a lot of them.

__But what to do about this?__

There are a few techniques you can use to improve the performance. Let's have a deeper look into them now.

## Lazy create a Throwable and reuse
There are some situations where you would like to use the same `Throwable` multiple times. In this case you can lazily create and then reuse it. This way you eliminate a lot of the initial overhead. 

To make things more clear let's have a look at some real-world example. In this example we assume that we have a list of pending writes which are all failed because the underlying `Channel` was closed. 

The pending writes are represented by the `PendingWrite` interface as shown below.

<pre class="syntax java"> 
public interface PendingWrite {
    void setSuccess();
    void setFailure(Throwable cause);
}
</pre>


We have a `Writer` class which will need to fail all `PendingWrite` instances with a `ClosedChannelException`. You may be tempted to implement it like this:

<pre class="syntax java">  
public class Writer {
       
    ....

    private void failPendingWrites(PendingWrite... writes) {
        for (PendingWrite write: writes) {
            write.setFailure(new ClosedChannelException());
        }    
    }
}
</pre>


This works, but if this method is called often and with a not to small array of `PendingWrite`s you are in serious trouble. It will need to fill in the stacktrace for every `PendingWrite` you are about to fail!
  
This is not only very wasteful but also something that is easy to optimize, so let's bring it on...

The key is to lazy create the `ClosedChannelException` and reuse it for each `PendingWrite` that needs to get failed. And doing so will even result in the correct stacktrace to be filled in... __JackPot!__

So fixing this is as easy as rewriting the `failPendingWrites(...)` method as shown here:

<pre class="syntax java">
public class Writer {
    ....

    private void failPendingWrites(PendingWrite... writes) {
        if (writes.length == 0) {
            return;
        }
        ClosedChannelException error = new ClosedChannelException();
        for (PendingWrite write: writes) {
            write.setFailure(error);
        }
    }
}
</pre>

Notice we lazily create the `ClosedChannelException` only if needed (if we have something to fail) and reuse the same instance for all the `PendingWrite`s in the array. This will dramatically cut down the overhead, but you can reduce it even more with some tradeoff which I will explain next...
  
## Use static Throwable with no stacktrace at all
Sometimes you may not need a stacktrace at all as the `Throwable` itself is enough information for what's going on. In this case, you are able to just use a static `Throwable` and reuse it.

What you should remember in this case is to set the stacktrace to an empty array to not have some "wrong" stacktrace show up, and so cause a lot of headache when debugging.

Let us see how this fit in again in our `Writer` class:

<pre class="syntax java">
public class Writer {
    private static final ClosedChannelException CLOSED_CHANNEL_EXCEPTION = new ClosedChannelException();
    static {
        CLOSED_CHANNEL_EXCEPTION.setStackTrace(new StackTraceElement[0]);
    }
    ....

    private void failPendingWrites(PendingWrite... writes) {
        for (PendingWrite write: writes) {
            write.setFailure(CLOSED_CHANNEL_EXCEPTION);
        }
    }
}
</pre>

But where is this useful? 

For example in a network application a closed `Channel` is not a really exceptional state anyway. So this may be a good fit in this case. In fact we do something similar in [Netty](http://netty.io) for exactly this case.

__Caution: only do this if you are sure you know what you are doing!__


## Benchmarks
Now with all the claims it's time to actually proof them. For this I wrote a microbenchmark using [JMH](http://openjdk.java.net/projects/code-tools/jmh/). 


You can find the source code of the benchmark in the [github repository](https://github.com/normanmaurer/jmh-benchmarks/tree/master/src/main/java/me/normanmaurer/benchmarks).
As there is no JMH version in any public maven repository yet I just bundled a SNAPSHOT version of it in the repository. As this is just a SNAPSHOT it may get out of date at some point in time.... Anyway this is good enough for us to run a benchmark and should be quite simple to be updated if needed.

This benchmark was run with:

    # git clone https://github.com/normanmaurer/jmh-benchmarks.git
    # cd jmh-benchmarks
    ➜  jmh-benchmarks git:(master) ✗ mvn clean package
    ➜  jmh-benchmarks git:(master) ✗ java -jar target/microbenchmarks.jar -w 10 -wi 3 -i 3 -of csv -o output.csv -odr ".*ThrowableBenchmark.*"

This basically means:

 * Clone the code
 * Build it the code
 * Run a warmup for 10 seconds
 * Run warmup 3 times
 * Run each benchmark 3 times
 * Generate output as csv

The benchmark result contains the ops/msec. Each op represents the call of `failPendingWrites(...)` with and array of 10000 `PendingWrite`s.

Enough said, time to look at the outcome:

![Throwable](/blog/images/benchmark_throwable.png "Benchmark of different usage of Throwable")

As you can see here creating a new `Throwable` is by far the slowest way to handle it. Next one is to lazily create a `Throwable` and reuse it for the whole method invocation. The winner is to reuse a static `Throwable` with the drawback of not having any stacktrace. So I think it's fair to say using a lazy created `Throwable` is the way to go in most cases. If you really need the last 1 % performance you could also make use of the static solution but will loose the stacktrace for debugging. So you see it's always a tradeoff.


## Summary
You should be aware of how expensive `Throwable.fillInStackTrace()` is and so think hard about how and when you create new instances of `Throwable`. This is also true for subtypes as those will call the super constructor.

To make it short, nothing is for free so think about what you are doing before you run into performance problems later.
Another good read on this topic is [the blog post of John Rose](https://blogs.oracle.com/jrose/entry/longjumps_considered_inexpensive).

Thanks again to [Nitsan Wakart](https://twitter.com/nitsanw) and [Michael Nitschinger](https://twitter.com/daschl) for the review!
