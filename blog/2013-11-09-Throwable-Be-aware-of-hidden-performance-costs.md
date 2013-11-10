---
layout: post
title: 'Throwable - Be aware of hidden performance costs'
author: normanmaurer
---

Today it's time to make you aware of the performance penalty you may pay when using `Throwable`, `Error`, `Exception` and so give you a better idea how to fix it... You may never have thought about it but using those in a wrong fashion may effect the performance of your applications in a some large degree.

Ok let us start from scratch here. You often may have heard that you should only use `Exception` / `Throwable` / `Error` for exceptional situations, something that is not the norm and signals some unexpected behaviour. This is actual a good advice but even if you follow it (which I really hope you do) there may be situations where you need to throw one.

Throwing a `Throwable` (or one of it's subtypes) is not a big deal. Well it's not for free but still not the main performance issue. The issue is what happens when you create it. 

> Huh ?

So why is creating a `Throwable` so expensive ? Isn't it just a simple leight-weight POJO? Simple yes, but leight-weight no! 

It's because usally it will call `Throwable.fillInStackTrace()`, which needs to look down the stack and put it in the newly created `Throwable`. This can affect the performance of your application in a very bad way if you create a lof of them.

__But what to do about this ?__

There are a few techniques you can use to improve performance for use-cases. Let us have a deeper look into them now.


## Lazy create a Throwable and re-use 

There are sometimes situations where you would like to use the same `Throwable` multiple times. In this case you can lazy create it and re-use it. This way you eliminate a lot of overhead as you will a lot less fill the stacktrace in. 

To make things more clear let us have a look at some real-world example. In this example we assume we have an array of pending writes, which are all need to be failed because the underlying `Channel` was closed. This is some common use-case in non-blocking like Frameworks like [Netty](http://netty.io) and [Vert.x](http://vertx.io).

The pending writes are represent by the `PendingWrite` interface as shown below.
    
    public interface PendingWrite {
        void setSuccess();
        void setFailure(Throwable cause);
    }


Then we have a `Writer` class which will need to fail all `PendingWrite` instances with a `ClosedChannelException`. You may be tempted to implement it like this:

    public class Writer {
       
        ....

        private void failPendingWrites(PendingWrite... writes) {
            for (PendingWrite write: writes) {
                write.setFailure(new ClosedChannelException();
            }    
        }
     }

This works but if this method is called often and with many `PendingWrite`s you are in serious trouble, as it will need to fill in the StackTrace for every `PendingWrite` you are about to fail!

This is not only very wasteful but also something that is easy to optimize! The key is to lazy create the `ClosedChannelException` and re-use it for each `PendingWrite` that needs to get failed. And doing so will even result in the correct StackTrace to be filled in... __JackPot!__

So fixing this is as easy as rewrite the `failPendingWrites(...)` method as shown here:

    public class Writer {
       ....

        private void failPendingWrites(PendingWrite... writes) {
            ClosedChannelException error = null;
            for (PendingWrite write: writes) {
                if (error == null) {
                    error = new ClosedChannelException();
                }
                write.setFailure(error);
            }
        }
     }

Notice we lazy create the `ClosedChannelException` if needed and re-use the same instance for all the `PendingWrite`s in the array during the method invocation.
This will cut-down the overhead dramatic, but you can reduce it even more with some tradeoff...

## Use static Throwable with no stacktrace at all

Sometimes you may not need a stacktrace at all as the `Throwable` itself is information enough what's going on. In this case you can just use a static `Throwablei` and reuse it.

What you should remember in this case is to set the stacktrace to an empty array to not have some "wrong" stacktrace show up. 


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


__Caution: only do this if you are sure you know what you are doing!__


## Benchmarks
Now with all the claims it's time to actual proof them. For this I wrote a microbenchmark using [JMH](http://openjdk.java.net/projects/code-tools/jmh/). 

You can find the source code of the benchmark in the [github repository](https://github.com/normanmaurer/jmh-samples/tree/master/src/main/java/me/normanmaurer/benchmarks).

This benchmark was run with:
    ➜  jmh-samples git:(master) ✗ java -jar target/microbenchmarks.jar -w 10 -wi 3 -i 3 -of csv -o output.csv -odr ".*ThrowableBenchmark.*"

This basically means:
 * Run a warmup for 10 seconds
 * Run warmup 3 times
 * Run each benchmark 3 times
 * Generate output as csv

The benchmark result contains the ops/msec. Each op represent the call of `fainlPendingWrites(...)` with and array of 10000 `PendingWrite`s.

Enough said, time to look at the outcome:

![Throwable](/blog/images/benchmark_throwable.png "Benchmark of different usage of Throwable")

As you can see here creating a new `Throwable` is by far the slowest way to handle it. Next one is to lazy create a `Throwable` and re-use it for the whole method invocation. The winner is to re-use a static `Throwable` with the drawback of not have any stacktrace. So I think it's fair to say using a lazy created `Throwable` is the way to go here. If you really need the last 1 % performance you could also make use of the static solution but will loose the stacktrace for debugging. So you see it's always a tradeoff.


## Summary
You should be aware of how expensive `fillInStackTrace()` is and so think hard about how and when you create new instances of it. This is also true for sub-types.

To make it short, nothing is for free so think about what you are doing before you run into performance problems later.
