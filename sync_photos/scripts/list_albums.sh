#!/bin/bash

# Path to your Photos.sqlite
DB_PATH="/mnt/iphone/PhotoData/Photos.sqlite"

# Run the query and output a nicely formatted table
sqlite3 "$DB_PATH" -column -header "
SELECT 
    a.Z_PK AS AlbumID,
    a.ZTITLE AS AlbumName,
    SUM(CASE WHEN z.ZFILENAME LIKE '%.MOV' OR z.ZFILENAME LIKE '%.MP4' THEN 0 ELSE 1 END) AS PhotoCount,
    SUM(CASE WHEN z.ZFILENAME LIKE '%.MOV' OR z.ZFILENAME LIKE '%.MP4' THEN 1 ELSE 0 END) AS VideoCount
FROM 
    ZGENERICALBUM a
LEFT JOIN 
    Z_30ASSETS za ON a.Z_PK = za.Z_30ALBUMS
LEFT JOIN 
    ZASSET z ON za.Z_3ASSETS = z.Z_PK
WHERE 
    a.ZKIND = 2
GROUP BY 
    a.Z_PK, a.ZTITLE
ORDER BY 
    a.ZTITLE;
"

