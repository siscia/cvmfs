/**
 * This file is part of the CernVM File System.
 */

#include "cvmfs_config.h"
#include "cmd_enter.h"

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cassert>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "logging.h"
#include "options.h"
#include "publish/except.h"
#include "util/posix.h"


using namespace std;  // NOLINT

namespace publish {

int CmdEnter::Main(const Options &options) {
  bool rvb;

  std::string fqrn = options.plain_args()[0].value_str;

  uid_t uid = geteuid();
  gid_t gid = getegid();
  printf("OUTER NS: uid %d   gid %d\n", uid, gid);

  string cwd = GetCurrentWorkingDirectory();
  string workspace = GetHomeDirectory() + "/.cvmfs/" + fqrn;
  const string path_usyslog = workspace + "/usyslog.log";
  const string path_cache = workspace + "/cache";
  const string path_config = workspace + "/client.config";
  const string path_mount_union = workspace + "/union";
  const string path_mount_rdonly = workspace + "/rdonly";
  const string path_mount_scratch = workspace + "/scratch";
  const string path_cvmfs2 =
    "/home/jakob/Documents/CERN/git/src/build-arch/cvmfs/cvmfs2";

  int rvi = unshare(CLONE_NEWUSER | CLONE_FS | CLONE_NEWNS);
  LogCvmfs(kLogCvmfs, kLogStdout, "unshare %d (%d), I am %d",
           rvi, errno, getuid());
  if (rvi != 0) throw EPublish("cannot create namespace");
  printf("INNER NS after unshare: uid %d   gid %d\n", geteuid(), getegid());

  string str_pid = StringifyInt(getpid());
  string path_uid_map = string("/proc/") + str_pid + "/uid_map";
  string path_gid_map = string("/proc/") + str_pid + "/gid_map";
  string path_setgroups = string("/proc/") + str_pid + "/setgroups";

  rvb = SafeWriteToFile(string("0 ") + StringifyInt(uid) + " 1", path_uid_map,
                        kDefaultFileMode);
  if (!rvb) throw EPublish("cannot set uid map");
  rvb = SafeWriteToFile("deny", path_setgroups, kDefaultFileMode);
  if (!rvb) throw EPublish("cannot set setgroups");
  rvb = SafeWriteToFile(string("0 ") + StringifyInt(gid) + " 1", path_gid_map,
                        kDefaultFileMode);
  if (!rvb) throw EPublish("cannot set gid map");

  printf("INNER NS initialized: uid %d/%d   gid %d/%d\n",
         getuid(), geteuid(), getgid(), getegid());

  rvi = chdir(cwd.c_str());
  if (rvi != 0) throw EPublish("cannot chdir to " + cwd);

  LogCvmfs(kLogCvmfs, kLogStdout, "Create workspace %s", workspace.c_str());
  rvb = MkdirDeep(workspace, kPrivateDirMode);
  if (!rvb) throw EPublish("cannot create workspace " + workspace);
  rvb = MkdirDeep(path_cache, kPrivateDirMode);
  if (!rvb) throw EPublish("cannot create " + path_cache);
  rvb = MkdirDeep(path_mount_union, kPrivateDirMode);
  if (!rvb) throw EPublish("cannot create " + path_mount_union);
  rvb = MkdirDeep(path_mount_rdonly, kPrivateDirMode);
  if (!rvb) throw EPublish("cannot create " + path_mount_rdonly);
  rvb = MkdirDeep(path_mount_scratch, kPrivateDirMode);
  if (!rvb) throw EPublish("cannot create " + path_mount_scratch);

  LogCvmfs(kLogCvmfs, kLogStdout, "Generating options for %s", fqrn.c_str());
  BashOptionsManager options_manager;
  options_manager.ParseDefault(fqrn);
  options_manager.SetValue("CVMFS_MOUNT_DIR", path_mount_rdonly);
  options_manager.SetValue("CVMFS_AUTO_UPDATE", "no");
  options_manager.SetValue("CVMFS_NFS_SOURCE", "no");
  options_manager.SetValue("CVMFS_HIDE_MAGIC_XATTRS", "yes");
  options_manager.SetValue("CVMFS_SERVER_CACHE_MODE", "yes");
  options_manager.SetValue("CVMFS_USYSLOG", path_usyslog);
  options_manager.SetValue("CVMFS_RELOAD_SOCKETS", path_cache);
  options_manager.SetValue("CVMFS_WORKSPACE", path_cache);
  options_manager.SetValue("CVMFS_CACHE_PRIMARY", "private");
  options_manager.SetValue("CVMFS_CACHE_private_TYPE", "posix");
  options_manager.SetValue("CVMFS_CACHE_private_BASE", path_cache);
  options_manager.SetValue("CVMFS_CACHE_private_SHARED", "on");
  options_manager.SetValue("CVMFS_CACHE_private_QUOTA_LIMIT", "4000");
  options_manager.SetValue("CVMFS_NFILES", "65538");
  rvb = SafeWriteToFile(options_manager.Dump(), path_config, kPrivateFileMode);

  vector<string> args;
  args.push_back("-o");
  args.push_back("config=" + path_config);
  args.push_back(fqrn);
  args.push_back(path_mount_rdonly);
  int fd_stdin;
  int fd_stdout;
  int fd_stderr;
  pid_t pid_cvmfs;
  rvb = ExecuteBinary(&fd_stdin, &fd_stdout, &fd_stderr, path_cvmfs2, args,
                      false, &pid_cvmfs);
  if (!rvb) {
    LogCvmfs(kLogCvmfs, kLogStderr, "Failed to launch %s", path_cvmfs2.c_str());
    return 32;
  }
  close(fd_stdin);

  int status;
  rvi = waitpid(pid_cvmfs, &status, 0);
  if (rvi == -1) {
    LogCvmfs(kLogCvmfs, kLogStderr, "Failed reading return code (%d)", errno);
    return 32;
  }
  if (!WIFEXITED(status) || (WEXITSTATUS(status) != 0)) {
    LogCvmfs(kLogCvmfs, kLogStderr, "Failure mounting");
    return 1;
  }

  LogCvmfs(kLogCvmfs, kLogStdout, "mounted read-only branch");
//  while (true) {
//    char c;
//    rvi = read(fd_stdoerr, &c, 1);
//    // in case something goes wrong...
//    if (rvi <= 0) break;
//
//    LogCvmfs(kLogCvmfs, kLogStdout | kLogNoLinebreak, "%c", c);
//  }

  return 0;
}

}  // namespace publish
