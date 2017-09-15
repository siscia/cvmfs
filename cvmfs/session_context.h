/**
 * This file is part of the CernVM File System.
 */

#ifndef CVMFS_SESSION_CONTEXT_H_
#define CVMFS_SESSION_CONTEXT_H_

#include <string>
#include <vector>

#include "pack.h"
#include "util_concurrency.h"

namespace upload {

struct CurlSendPayload {
  const std::string* json_message;
  ObjectPackProducer* pack_serializer;
  size_t index;
};

size_t SendCB(void* ptr, size_t size, size_t nmemb, void* userp);
size_t RecvCB(void* buffer, size_t size, size_t nmemb, void* userp);

/**
 * This class implements a context for a single publish operation
 *
 * The context is created at the start of a publish operation and
 * is supposed to live at least until the payload has been submitted
 * to the repo services.
 *
 * It is the GatewayUploader concrete class which handles the creation and
 * destruction of the SessionContext. A session should begin when the spooler
 * and uploaders are initialized and should last until the call to
 * Spooler::WaitForUpload().
 */
class SessionContext {
 public:
  SessionContext();

  virtual ~SessionContext();

  bool Initialize(const std::string& api_url, const std::string& session_token,
                  const std::string& key_id, const std::string& secret,
                  uint64_t max_pack_size = ObjectPack::kDefaultLimit);
  bool Finalize(const std::string& old_root_hash,
                const std::string& new_root_hash);

  void WaitForUpload();

  ObjectPack::BucketHandle NewBucket();

  bool CommitBucket(const ObjectPack::BucketContentType type,
                    const shash::Any& id, const ObjectPack::BucketHandle handle,
                    const std::string& name = "",
                    const bool force_dispatch = false);

 protected:
  struct UploadJob {
    ObjectPack* pack;
    Future<bool>* result;
  };

  virtual bool Commit(const std::string& old_root_hash,
                      const std::string& new_root_hash);

  virtual Future<bool>* DispatchObjectPack(ObjectPack* pack);

  virtual bool DoUpload(const SessionContext::UploadJob* job);

 private:
  void Dispatch();

  static void* UploadLoop(void* data);

  bool ShouldTerminate();

  bool JobsPending() const;

  void IncrementDispatchedJobs();
  void IncrementFinishedJobs();

  FifoChannel<UploadJob*> upload_jobs_;
  FifoChannel<Future<bool>*> upload_results_;

  std::string api_url_;
  std::string session_token_;
  std::string key_id_;
  std::string secret_;

  atomic_int32 worker_terminate_;
  pthread_t worker_;

  uint64_t max_pack_size_;

  std::vector<ObjectPack::BucketHandle> active_handles_;

  ObjectPack* current_pack_;
  pthread_mutex_t current_pack_mtx_;

  uint64_t jobs_dispatched_;
  uint64_t jobs_finished_;
  mutable pthread_mutex_t job_counter_mtx_;

  uint64_t bytes_committed_;
  uint64_t bytes_dispatched_;
};

}  // namespace upload

#endif  // CVMFS_SESSION_CONTEXT_H_
