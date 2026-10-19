package main

import (
	"flag"
	"fmt"
	"log"

	"micagoserver/internal/app"
	"micagoserver/internal/version"
)

func main() {
	showVersion := flag.Bool("version", false, "print version, commit, build time and exit")
	syncOnce := flag.Bool("sync-once", false, "run one relay.db sync and exit")
	syncInterval := flag.String("sync-interval", "", "periodic relay sync interval")
	disableSyncLoop := flag.Bool("disable-sync-loop", false, "disable periodic relay sync loop")
	addr := flag.String("addr", "", "HTTP listen address")
	token := flag.String("token", "", "local administrator bearer token")
	publicURL := flag.String("public-url", "", "public base URL used for server info")
	flag.Parse()

	if *showVersion {
		fmt.Println(version.String())
		return
	}

	if err := app.Run(app.Options{
		SyncOnce:        *syncOnce,
		SyncInterval:    *syncInterval,
		DisableSyncLoop: *disableSyncLoop,
		Addr:            *addr,
		Token:           *token,
		PublicURL:       *publicURL,
	}); err != nil {
		log.Fatal(err)
	}
}
