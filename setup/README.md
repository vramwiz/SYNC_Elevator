# SYNC_Elevator の配布ZIP

`setup\make_release_zip.bat` を実行すると、Release の `SYNC_Elevator.auf2` を `setup\SYNC_Elevator.zip` に梱包し、`SYNC_Elevator.catalog.json` に同じファイルの XXH3-128 を記録します。

必要なファイルは `SYNC_Elevator.auf2` と [xxHash 公式 Windows 版の `xxhsum.exe`](https://github.com/Cyan4973/xxHash/releases/tag/v0.8.4) です。参照先を明示する場合は、下記のように指定します。

```bat
setup\make_release_zip.bat -ReleaseDirectory "D:\Release\SYNC_Elevator" -XxhsumPath "D:\Tools\xxhsum.exe"
```

ZIP の `SYNC_Elevator/` には、本体、利用者向け README とその画像、ライセンスと出典を収録します。カタログは初回版 `v1.0.0` から管理します。末尾のバージョン・公開日を更新し、同じタグの GitHub Release に ZIP とカタログ JSON を添付します。
