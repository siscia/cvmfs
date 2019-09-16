/**
 * This file is part of the CernVM File System.
 */

#include "cvmfs_config.h"
#include "task_hash.h"

#include <cstdlib>

#include "hash.h"

#include "coz.h"

void TaskHash::Process(BlockItem *input_block) {
  COZ_PROGRESS_NAMED("HASH BEGIN");
  ChunkItem *chunk = input_block->chunk_item();
  assert(chunk != NULL);

  switch (input_block->type()) {
    case BlockItem::kBlockData:
      shash::Update(input_block->data(), input_block->size(),
                    chunk->hash_ctx());
      break;
    case BlockItem::kBlockStop:
      shash::Final(chunk->hash_ctx(), chunk->hash_ptr());
      break;
    default:
      abort();
  }

  tubes_out_->Dispatch(input_block);
  COZ_PROGRESS_NAMED("HASH END");
}
