# Defect report

An engine developer who uses the native kernel library reports (verbatim):

> Since the latest kernel build, `WHERE` filters on INT64 columns return wrong
> rows on larger tables when native kernels are enabled (we pin `PQ_KERNELS_VARIANT=neon` on our ARM servers). The number of
> matching rows is right, but some of the returned rows are rows from near the
> beginning of the table instead of the rows that actually match. Tables with a
> few thousand rows are fine, and the same queries are correct with
> `PQ_KERNELS_VARIANT=scalar`.

The public test suite (`make -C native-kernels test`) passes; the acceptance
tests of this task include additional tests you do not have.
