package lib

import (
	"fmt"
	"io/ioutil"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// this flag is populated in the main `rootCmd` (cmd/root.go)
var (
	TemporaryBaseDir string
)

func UserDefinedTempDir(dir, prefix string) (name string, err error) {
	if strings.HasPrefix(dir, TemporaryBaseDir) {
		return ioutil.TempDir(dir, prefix)
	}
	return ioutil.TempDir(path.Join(TemporaryBaseDir, dir), prefix)
}

// best effort, if it fails somehow we just ignore it
func CreateAtlasTimestampLog(repo string) {
	if !RepositoryUpdated {
		Log().Info("Repository not updated")
		return
	}
	dir, err := UserDefinedTempDir("", "AtlasTimeLog")
	if err != nil {
		LogE(err).Error("Error in creating temp directory for atlas time log")
		return
	}
	filepath := filepath.Join(dir, "lastUpdate")

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unpacked.cern.ch"
	}
	now := time.Now()
	sec := now.Unix()
	month := now.Month().String()[0:3]
	year := now.Year()
	day := now.Day()
	hour := now.Hour()
	minute := now.Minute()

	buf := fmt.Sprintf("%d%s%02d %02d:%02d | %s | %d\n", year, month, day, hour, minute, hostname, sec)

	err = ioutil.WriteFile(filepath, []byte(buf), 0666)
	if err != nil {
		LogE(err).Error("Error in creating the Atlas log time")
		return
	}
	err = IngestIntoCVMFS(repo, "logDir/lastUpdate", filepath)
	if err != nil {
		LogE(err).Error("Error in ingesting the file into the repository")
	}
}
