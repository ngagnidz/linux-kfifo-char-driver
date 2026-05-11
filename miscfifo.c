// SPDX-License-Identifier: GPL-2.0-only
// Misc character device backed by a kfifo.
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/kfifo.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/wait.h>

// Buffer size for the kfifo.
static unsigned int buffer_size = 1024;
module_param(buffer_size, uint, 0444);
MODULE_PARM_DESC(buffer_size,
                 "FIFO size in bytes (set at insmod; default 1024, max 1 MiB)");
#define MISCFIFO_FIFO_MAX (1024 * 1024)

// Wait queues for the reader and writer.
static DECLARE_WAIT_QUEUE_HEAD(miscfifo_read_wq);
static DECLARE_WAIT_QUEUE_HEAD(miscfifo_write_wq);

// The kfifo and mutex for the reader and writer.
static struct kfifo miscfifo_fifo;
static DEFINE_MUTEX(miscfifo_lock);

static int miscfifo_open(struct inode *inode, struct file *file) {
  /* Silence unused parameters to avoid compiler warnings. */
  (void)inode;
  (void)file;
  return 0;
}

static int miscfifo_release(struct inode *inode, struct file *file) {
  (void)inode;
  (void)file;
  return 0;
}

static ssize_t miscfifo_read(struct file *file, char __user *ubuf, size_t len,
                             loff_t *off) {
  unsigned int copied = 0;
  int ret;

  /* If reading 0 bytes, return 0 - We do not want to sleep or lock the mutex
   * because we are not reading anything anyways*/
  if (!len)
    return 0;

  /* Try to lock the mutex. Handle interrupts. */
  ret = mutex_lock_interruptible(&miscfifo_lock);
  if (ret)
    return -ERESTARTSYS;

  /* Sleep until the writer writes to the fifo. */
  while (kfifo_is_empty(&miscfifo_fifo)) {

    /* Unlock the mutex to allow the other thread (writer) to write to the fifo.
     */
    mutex_unlock(&miscfifo_lock);

    /* Handle non-blocking mode */
    if (file->f_flags & O_NONBLOCK)
      return -EAGAIN;

    /* Sleep if the fifo is empty and put the reader in the wait queue. */
    ret = wait_event_interruptible(miscfifo_read_wq,
                                   !kfifo_is_empty(&miscfifo_fifo));
    if (ret)
      return -ERESTARTSYS;

    /* We do not have the lock yet. As a result, another thread might have read
     the fifo before we attempt to lock the mutex. Hence, acquire lock but
     execute the while loop check again.*/
    ret = mutex_lock_interruptible(&miscfifo_lock);
    if (ret)
      return -ERESTARTSYS;
  }

  ret = kfifo_to_user(&miscfifo_fifo, ubuf, len, &copied);
  mutex_unlock(&miscfifo_lock);

  /* Copied might not be greater than 0 if EFAULT gets triggered (kfifo failed
  to copy data due to user space buffer being invalid).*/
  if (copied > 0)
    wake_up_interruptible(&miscfifo_write_wq);

  if (ret)
    return ret;
  return copied;
}

// Same logic as read, but in reverse.
static ssize_t miscfifo_write(struct file *file, const char __user *buf,
                              size_t count, loff_t *pos) {
  unsigned int copied = 0;
  int ret;

  if (!count)
    return 0;

  ret = mutex_lock_interruptible(&miscfifo_lock);
  if (ret)
    return -ERESTARTSYS;

  while (kfifo_is_full(&miscfifo_fifo)) {

    mutex_unlock(&miscfifo_lock);

    if (file->f_flags & O_NONBLOCK)
      return -EAGAIN;

    ret = wait_event_interruptible(miscfifo_write_wq,
                                   !kfifo_is_full(&miscfifo_fifo));
    if (ret)
      return -ERESTARTSYS;

    ret = mutex_lock_interruptible(&miscfifo_lock);
    if (ret)
      return -ERESTARTSYS;
  }

  ret = kfifo_from_user(&miscfifo_fifo, buf, count, &copied);

  mutex_unlock(&miscfifo_lock);

  if (copied > 0)
    wake_up_interruptible(&miscfifo_read_wq);

  if (ret)
    return ret;
  return copied;
}

static const struct file_operations miscfifo_fops = {
    .owner = THIS_MODULE,
    .open = miscfifo_open,
    .read = miscfifo_read,
    .write = miscfifo_write,
    .release = miscfifo_release,
    .llseek = no_llseek,
};

static struct miscdevice miscfifo_device = {
    .name = "miscfifo0",
    .minor = MISC_DYNAMIC_MINOR,
    .fops = &miscfifo_fops,
    .mode = 0666,
};

static int __init miscfifo_init(void) {
  int err;

  if (!buffer_size || buffer_size > MISCFIFO_FIFO_MAX) {
    pr_err("miscfifo: invalid buffer_size %u\n", buffer_size);
    return -EINVAL;
  }

  err = kfifo_alloc(&miscfifo_fifo, buffer_size, GFP_KERNEL);
  if (err) {
    pr_err("miscfifo: kfifo_alloc failed (%d)\n", err);
    return err;
  }

  err = misc_register(&miscfifo_device);
  if (err) {
    pr_err("miscfifo: misc_register failed (%d)\n", err);
    kfifo_free(&miscfifo_fifo);
    return err;
  }

  pr_info("miscfifo: init (buffer_size=%u bytes)\n", buffer_size);
  return 0;
}

static void __exit miscfifo_exit(void) {
  misc_deregister(&miscfifo_device);
  kfifo_free(&miscfifo_fifo);
  pr_info("miscfifo: exit\n");
}

module_init(miscfifo_init);
module_exit(miscfifo_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Nikoloz Gagnidze");
MODULE_DESCRIPTION(
    "Misc char device with kfifo supporting blocking/non-blocking I/O");
MODULE_VERSION("0.2");