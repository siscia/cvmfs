/**
 * This file is part of the CernVM File System.
 */

#include "upload_facility.h"

#include "upload_local.h"
#include "util.h"

using namespace upload;

void AbstractUploader::RegisterPlugins() {
  RegisterPlugin<LocalUploader>();
}


AbstractUploader::AbstractUploader(const SpoolerDefinition& spooler_definition) :
  spooler_definition_(spooler_definition),
  writer_thread_(&ThreadProxy<AbstractUploader>,
                 this,
                 &AbstractUploader::WriteThread) {}


bool AbstractUploader::Initialize() {
  return true;
}


void AbstractUploader::WaitForUpload() const {}


void AbstractUploader::Respond(const callback_t       *callback,
                               const UploaderResults  &result) const {
  if (callback == NULL) {
    return;
  }

  (*callback)(result);
  delete callback;
}
