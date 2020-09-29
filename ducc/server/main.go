package main

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/cvmfs/ducc/lib"
	cvmfs "github.com/cvmfs/ducc/server/cvmfs"
	res "github.com/cvmfs/ducc/server/replies"
	"github.com/julienschmidt/httprouter"
)

type Repo struct {
	*cvmfs.Repository
}

func NewRepo(name string) Repo {
	r := cvmfs.NewRepository(name)
	return Repo{r}
}

func (repo *Repo) statusLayer(w http.ResponseWriter, r *http.Request, p httprouter.Params) {
	// the layer to be correctly ingested, need to:
	// 1. Exists
	// 2. Have the layerfs directory
	// 3. Have the .metadata directory
	// 4. Have the origin.json inside the .metadata directory
	// 5. Have the .cvmfs catalog inside the layerfs directory
	// if all these conditions are met, the layer is correctly ingested

	layerErrors := make([]res.DUCCStatError, 0)
	pathsToCheck := make([]string, 0, 5)

	path := lib.LayerPath(repo.Name, p.ByName("digest"))
	pathsToCheck = append(pathsToCheck, path)

	layerfs := lib.LayerRootfsPath(repo.Name, p.ByName("digest"))
	catalog := filepath.Join(layerfs, ".cvmfscatalog")
	pathsToCheck = append(pathsToCheck, layerfs)
	pathsToCheck = append(pathsToCheck, catalog)

	metadata := lib.LayerMetadataPath(repo.Name, p.ByName("digest"))
	origin := filepath.Join(metadata, "origin.json")
	pathsToCheck = append(pathsToCheck, metadata)
	pathsToCheck = append(pathsToCheck, origin)

	for _, path := range pathsToCheck {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			layerErrors = append(layerErrors, res.NewDUCCStatError(path, err))
		}
	}

	if len(layerErrors) == 0 {
		result := res.NewLayerStatusOk()
		response, jsonErr := json.Marshal(result)
		if jsonErr != nil {
			http.Error(w, jsonErr.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(response)
	} else {
		result := res.NewLayerStatusErr(layerErrors)
		response, jsonErr := json.Marshal(result)
		if jsonErr != nil {
			http.Error(w, jsonErr.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(response)
	}
}

// to ingest layers we need to create the directory structure
// add all the catalogs in there
// before to create anything we need to make sure that the stuff are not there
// we should try to limit the number of transactions
// one idea would be to first check what is missing, and the in one transaction batch all the changes

// add directory
// add file
// add link
// remove directory
// remove file
// remove link

func (repo Repo) ingestLayerFileSystem(w http.ResponseWriter, r *http.Request, p httprouter.Params) {
	log.Printf("Receiving new layer: %s", p.ByName("digest"))
	defer log.Printf("Done with layer: %s", p.ByName("digest"))
	// we get the path where to ingest the layer
	layerfs := lib.LayerRootfsPath(repo.Name, p.ByName("digest"))

	layerParent := lib.LayerParentPath(repo.Name, p.ByName("digest"))
	createCvmfsCatalog := cvmfs.NewAddCVMFSCatalog(layerParent)
	index, err := repo.AddFSOperations(createCvmfsCatalog)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	err = repo.WaitFor(index)
	if err != nil {
		if errors.Is(err, cvmfs.WaitForNotScheduledError) {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	gzip, err := gzip.NewReader(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer gzip.Close()

	ingestTar := cvmfs.NewIngestTar(gzip, layerfs)
	index, err = repo.AddFSOperations(ingestTar)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	err = repo.WaitFor(index)
	if err != nil {
		if errors.Is(err, cvmfs.WaitForNotScheduledError) {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	if ingestTar.FirstError() != nil {
		fmt.Println(ingestTar.FirstError())
		http.Error(w, ingestTar.FirstError().Error(), http.StatusInternalServerError)
		return
	}
	result := res.NewLayerSuccessfullyIngested(p.ByName("digest"))
	response, jsonErr := json.Marshal(result)
	if jsonErr != nil {
		http.Error(w, jsonErr.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
	w.Header().Set("Content-Type", "application/json")
	w.Write(response)
}

func (repo Repo) ingestLayerOrigin(w http.ResponseWriter, r *http.Request, p httprouter.Params) {
}

func main() {
	repo := NewRepo("new-unpacked.cern.ch")
	go repo.StartOperationsLoop()
	router := httprouter.New()
	router.GET("/layer/status/:digest", repo.statusLayer)
	router.POST("/layer/filesystem/:digest", repo.ingestLayerFileSystem)
	router.POST("/layer/origin/:digest", repo.ingestLayerOrigin)

	log.Fatal(http.ListenAndServe(":8080", router))
}
