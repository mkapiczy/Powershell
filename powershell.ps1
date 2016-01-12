# Załadowanie potrzebnych zależności
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | Out-Null; 
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMOExtended")| Out-Null; 


####################### Funkcja łączy się z serwerem i wynik zapytania
function Get-SqlData
{
    param([string]$serverName=$(throw 'serverName is required.'), [string]$databaseName=$(throw 'databaseName is required.'),
          [string]$query=$(throw 'query is required.'))

    Write-Verbose "Get-SqlData serverName:$serverName databaseName:$databaseName query:$query"

    $connString = "Server=$serverName;Database=$databaseName;Integrated Security=SSPI;"
    $da = New-Object "System.Data.SqlClient.SqlDataAdapter" ($query,$connString)
    $dt = New-Object "System.Data.DataTable"
    $da.fill($dt) > $null
    $dt

} #Get-SqlData

####################### Funkcja zwracająca metadane bazy
function Get-SqlMeta
{
    param($serverName, $DatabaseName, $schema='dbo', $name)

$qry =
@"
DECLARE @schema varchar(255), @name varchar(255)
SELECT @schema = '$schema', @name = '$name'
;WITH pk AS
(
SELECT kcu.TABLE_SCHEMA, kcu.TABLE_NAME, kcu.COLUMN_NAME
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS tc
JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS kcu
ON kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
AND kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
AND kcu.TABLE_SCHEMA = tc.TABLE_SCHEMA
AND kcu.TABLE_NAME = tc.TABLE_NAME
WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
),
fk AS
(
SELECT DISTINCT C.TABLE_SCHEMA [PKTABLE_SCHEMA], C.TABLE_NAME [PKTABLE_NAME]
, C2.TABLE_SCHEMA [FKTABLE_SCHEMA], C2.TABLE_NAME [FKTABLE_NAME]
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS C 
INNER JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS RC 
ON C.CONSTRAINT_SCHEMA = RC.CONSTRAINT_SCHEMA 
AND C.CONSTRAINT_NAME = RC.CONSTRAINT_NAME 
INNER JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS C2 
ON RC.UNIQUE_CONSTRAINT_SCHEMA = C2.CONSTRAINT_SCHEMA 
AND RC.UNIQUE_CONSTRAINT_NAME = C2.CONSTRAINT_NAME 
WHERE  C.CONSTRAINT_TYPE = 'FOREIGN KEY'
),
col AS
(
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME NOT IN ('dtproperties','sysdiagrams')
AND OBJECTPROPERTY(OBJECT_ID('['+TABLE_SCHEMA+'].['+TABLE_NAME+']'),'IsMSShipped') = 0
),
op AS
(
SELECT 
TABLE_SCHEMA, TABLE_NAME,
CASE CONSTRAINT_TYPE 
WHEN 'PRIMARY KEY' THEN 'PK'
WHEN 'FOREIGN KEY' THEN 'FK'
ELSE CONSTRAINT_TYPE
END + ': ' + CONSTRAINT_NAME AS operation
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA IS NOT NULL
UNION
SELECT OBJECT_SCHEMA_NAME(parent_obj) AS TABLE_SCHEMA, OBJECT_NAME(parent_obj) AS TABLE_NAME, 'Trigger: ' + name
FROM sysobjects
WHERE type = 'TR'
UNION
SELECT OBJECT_SCHEMA_NAME(object_id) AS TABLE_SCHEMA, OBJECT_NAME(object_id) AS TABLE_NAME, 'Index: ' + name
FROM sys.indexes
LEFT JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS
ON TABLE_SCHEMA = OBJECT_SCHEMA_NAME(object_id)
AND TABLE_NAME = OBJECT_NAME(object_id)
AND CONSTRAINT_NAME = name
WHERE OBJECTPROPERTY(object_id,'IsMSShipped') = 0
AND name IS NOT NULL
AND TABLE_SCHEMA IS NULL
)
SELECT class.TABLE_SCHEMA + '.' + class.TABLE_NAME AS 'table', 
(SELECT ISNULL(REPLACE(pk.COLUMN_NAME,pk.COLUMN_NAME,'PK '),'') + col.COLUMN_NAME + ': ' + col.DATA_TYPE
FROM col 
LEFT JOIN pk
ON col.TABLE_SCHEMA = pk.TABLE_SCHEMA
AND col.TABLE_NAME = pk.TABLE_NAME
AND col.COLUMN_NAME = pk.COLUMN_NAME
WHERE class.TABLE_SCHEMA = col.TABLE_SCHEMA AND class.TABLE_NAME = col.TABLE_NAME 
FOR XML PATH('column'), TYPE) AS 'columns', 
(SELECT '[' + fk.FKTABLE_SCHEMA + '.' + fk.FKTABLE_NAME + ']'
FROM fk WHERE class.TABLE_SCHEMA = fk.PKTABLE_SCHEMA AND class.TABLE_NAME = fk.PKTABLE_NAME 
FOR XML PATH('relation'), TYPE) AS 'relations',
(SELECT '' + operation 
FROM op where class.TABLE_SCHEMA = op.TABLE_SCHEMA AND class.TABLE_NAME = op.TABLE_NAME
FOR XML PATH('operation'),TYPE) AS 'operations'
FROM INFORMATION_SCHEMA.TABLES class
WHERE class.TABLE_SCHEMA = @schema
AND class.TABLE_NAME = @name
--class.TABLE_TYPE = 'BASE TABLE'
--AND OBJECTPROPERTY(OBJECT_ID('['+class.TABLE_SCHEMA+'].['+class.TABLE_NAME+']'),'IsMSShipped') = 0
--AND class.TABLE_NAME NOT IN ('dtproperties','sysdiagrams')
ORDER BY class.TABLE_SCHEMA + '.' + class.TABLE_NAME
FOR XML AUTO, ELEMENTS, ROOT('root')
"@

    Get-SqlData $serverName $databaseName $qry

} #Get-SqlMeta

####################### Funkcja konwertuje metadane otrzymane z zapytania na dane potrzebne do yUML
function ConvertTo-yUML {
    param ([xml]$meta)

    $r = $meta.root.class | foreach {'[' + $_.table + '|'}
    $table = $meta.root.class | foreach {'[' + $_.table + ']'}

    $cols = $meta.root.class | foreach {$_.columns.column}
    $r += [string]::join(';',$cols)

    $ops = $meta.root.class | foreach {$_.operations.operation}
    if ($ops)
    { $r += '|' + [string]::join(';',$ops) }
    
    $r += ']' 

    $rels = $meta.root.class | foreach {$_.relations.relation}
    if ($rels)
    { $r +=  ",$table->" + [string]::join(",$table->",$rels) }

	#$r | Write-Host
    $r

} #ConvertTo-yUML

####################### Funkcja generująca diagramy UML'owe poprzez WebService yUML
Function Get-yUMLDiagram {
    param(
        $yUML, 
		$table,
		$imagesFilePath,
        [switch]$download

    )
    
    $base = "http://yuml.me/diagram/scruffy/class/"
    $address = $base + $yUML
    
    
    if($download) { 
	 $imagesFilePath = "$env:USERPROFILE\database_documentation\"+$db.Name+"\images\"; 
	 $diagramFileName=$imagesFilePath+$table.Name+".jpg"
     $wc = New-Object Net.WebClient
		$wc.DownloadFile($address, $diagramFileName)
    } else {
        $address
    }
}


# Funkcja tworząca stronę html
function writeHtmlPage 
{ 
    param ($title, $heading, $body, $filePath); 
    $html = "<html> 
             <head> 
                 <title>$title</title> 
             </head> 
             <body> 
                 <h1>$heading</h1> 
                $body 
             </body> 
             </html>"; 
    $html | Out-File -FilePath $filePath; 
} 
 
# Pobiera wszystkie bazy danych na wskazanym serwerze
function getDatabases 
{ 
    param ($sql_server); 
    $databases = $sql_server.Databases | Where-Object {$_.IsSystemObject -eq $false}; 
    return $databases; 
} 
 
# Pobiera wszystkie schematy dla bazy danych
function getDatabaseSchemata 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $schemata = $sql_server.Databases[$db_name].Schemas; 
    return $schemata; 
} 
 
# Pobiera wszystkie tabele dla bazy danych
function getDatabaseTables 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $tables = $sql_server.Databases[$db_name].Tables | Where-Object {$_.IsSystemObject -eq $false}; 
    return $tables; 
} 
 
# Pobiera wszystkie procedury dla bazy danych
function getDatabaseStoredProcedures 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $procs = $sql_server.Databases[$db_name].StoredProcedures | Where-Object {$_.IsSystemObject -eq $false}; 
    return $procs; 
} 
 
# Pobiera wszystkie funkcje dla bazy danych
function getDatabaseFunctions 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $functions = $sql_server.Databases[$db_name].UserDefinedFunctions | Where-Object {$_.IsSystemObject -eq $false}; 
    return $functions; 
} 
 
# Pobiera widoki dla bazy danych
function getDatabaseViews 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $views = $sql_server.Databases[$db_name].Views | Where-Object {$_.IsSystemObject -eq $false}; 
    return $views; 
} 
 
# Pobiera triggery dla bazy danych
function getDatabaseTriggers 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $tables = $sql_server.Databases[$db_name].Tables | Where-Object {$_.IsSystemObject -eq $false}; 
    $triggers = $null; 
    foreach($table in $tables) 
    { 
        $triggers += $table.Triggers; 
    } 
    return $triggers; 
} 
 
# Tworzy linki między obiektami
function buildLinkList 
{ 
    param ($array, $path); 
    $output = "<ul>"; 
    foreach($item in $array) 
    { 
        if($item.IsSystemObject -eq $false) # Wyklucz obiekty systemowe
        {     
            if([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Schema") 
            { 
                $output += "`n<li><a href=`"$path" + $item.Name + ".html`">" + $item.Name + "</a></li>"; 
            } 
            elseif([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Trigger") 
            { 
                $output += "`n<li><a href=`"$path" + $item.Parent.Schema + "." + $item.Name + ".html`">" + $item.Parent.Schema + "." + $item.Name + "</a></li>"; 
            } 
            else 
            { 
                $output += "`n<li><a href=`"$path" + $item.Schema + "." + $item.Name + ".html`">" + $item.Schema + "." + $item.Name + "</a></li>"; 
            } 
        } 
    } 
    $output += "</ul>"; 
    return $output; 
} 
 
# Zwraca DDL dla danego obiektu bazodanowego
function getObjectDefinition 
{ 
    param ($item); 
    $definition = ""; 
    # Schematy nie lubią "ScriptingOprions"
    if([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Schema") 
    { 
        $definition = $item.Script(); 
    } 
    else 
    { 
        $options = New-Object ('Microsoft.SqlServer.Management.Smo.ScriptingOptions'); 
        $options.DriAll = $true; 
        $options.Indexes = $true; 
        $definition = $item.Script($options); 
    } 
    return "<pre>$definition</pre>"; 
} 
 
# Funkcja zwraca komentarze przypisane do obiektu poprzez SSMS
function getDescriptionExtendedProperty 
{ 
    param ($item); 
    $description = "  ---------------   "; 
    foreach($property in $item.ExtendedProperties) 
    { 
        if($property.Name -eq "MS_Description") 
        { 
            $description = $property.Value; 
        } 
    } 
    return $description; 
} 
 
# PObiera parametry dla stored procedures
function getProcParameterTable 
{ 
    param ($proc); 
    $proc_params = $proc.Parameters; 
    $prms = $proc_params | ConvertTo-Html -Fragment -Property Name, DataType, DefaultValue, IsOutputParameter; 
    return $prms; 
} 
 
# Zwraca tabelę html ze szczegółami tabeli
function getTableColumnTable 
{ 
    param ($table); 
    $table_columns = $table.Columns; 
    $objs = @(); 
    foreach($column in $table_columns) 
    { 
        $obj = New-Object -TypeName Object; 
        $description = getDescriptionExtendedProperty $column; 
        Add-Member -Name "Name" -MemberType NoteProperty -Value $column.Name -InputObject $obj; 
        Add-Member -Name "DataType" -MemberType NoteProperty -Value $column.DataType -InputObject $obj; 
        Add-Member -Name "Default" -MemberType NoteProperty -Value $column.Default -InputObject $obj; 
        Add-Member -Name "Identity" -MemberType NoteProperty -Value $column.Identity -InputObject $obj; 
        Add-Member -Name "InPrimaryKey" -MemberType NoteProperty -Value $column.InPrimaryKey -InputObject $obj; 
        Add-Member -Name "IsForeignKey" -MemberType NoteProperty -Value $column.IsForeignKey -InputObject $obj; 
        Add-Member -Name "Description" -MemberType NoteProperty -Value $description -InputObject $obj; 
        $objs = $objs + $obj; 
    } 
    $cols = $objs | ConvertTo-Html -Fragment -Property Name, DataType, Default, Identity, InPrimaryKey, IsForeignKey, Description; 
    return $cols; 
} 

#Pobiera diagram UML dla tabeli
function getTableUML
{
	param ($table, $imagesFilePath); 
	$serverName = 'localhost';$databaseName = $db.Name; $schema='dbo';$name=$table.Name
	$meta = Get-SqlMeta $serverName $databaseName $schema $name
    #$meta[0] | Write-Host
	$yUML = (ConvertTo-yUML $meta[0])
	Get-yUMLDiagram $yUML $table $imagesFilePath -download
    
}
 
# Zwraca tabelę htmlową ze szczegółami triggera
function getTriggerDetailsTable 
{ 
    param ($trigger); 
    $trigger_details = $trigger | ConvertTo-Html -Fragment -Property IsEnabled, CreateDate, DateLastModified, Delete, DeleteOrder, Insert, InsertOrder, Update, UpdateOrder; 
    return $trigger_details; 
} 
 
# Funkcja tworzy wszystkie strony html dla obiektów
function createObjectTypePages 
{ 
    param ($objectName, $objectArray, $filePath, $db, $imagesFilePath); 
    New-Item -Path $($filePath + $db.Name + "\$objectName") -ItemType directory -Force | Out-Null; 
    # Stwórz stronę indexową dla obiektu
    $page = $filePath + $($db.Name) + "\$objectName\index.html"; 
    $list = buildLinkList $objectArray ""; 
    if($objectArray -eq $null) 
    { 
        $list = "No $objectName in $db"; 
    } 
    writeHtmlPage $objectName $objectName $list $page; 
    # Poszczególne strony
    if($objectArray.Count -gt 0) 
    { 
        foreach ($item in $objectArray) 
        { 
            if($item.IsSystemObject -eq $false) # Wyklucz obiekty systemowe 
            { 
                $description = getDescriptionExtendedProperty($item); 
                $body = "<h2>Description</h2>$description"; 
                $definition = getObjectDefinition $item; 
				
                if([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Schema") 
                { 
                    $page = $filePath + $($db.Name + "\$objectName\" + $item.Name + ".html"); 
                } 
                elseif([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Trigger") 
                { 
                    $page = $filePath + $($db.Name + "\$objectName\" + $item.Parent.Schema + "." + $item.Name + ".html"); 
                    Write-Host $path; 
                } 
                else 
                { 
                    $page = $filePath + $($db.Name + "\$objectName\" + $item.Schema + "." + $item.Name + ".html"); 
                } 
                $title = ""; 
                if([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Schema") 
                { 
                    $title = $item.Name; 
                    $body += "<h2>Object Definition</h2>$definition"; 
                } 
                else 
                { 
                    $title = $item.Schema + "." + $item.Name; 
                    if(([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.StoredProcedure") -or ([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.UserDefinedFunction")) 
                    { 
                        $proc_params = getProcParameterTable $item; 
                        $body += "<h2>Parameters</h2>$proc_params<h2>Object Definition</h2>$definition"; 
                    } 
                    elseif([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Table") 
                    { 
                        $cols = getTableColumnTable $item; 
						getTableUML $item, $imagesFilePath;
                        $body += "<h2>Columns</h2>$cols<h2>UML</h2><img src="+$imagesFilePath+$item.Name+".jpg><h2>Object Definition</h2>$definition"; 

                    } 
                    elseif([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.View") 
                    { 
                        $cols = getTableColumnTable $item; 
                        $body += "<h2>Columns</h2>$cols<h2>Object Definition</h2>$definition"; 
                    } 
                    elseif([string]$item.GetType() -eq "Microsoft.SqlServer.Management.Smo.Trigger") 
                    { 
                        $title = $item.Parent.Schema + "." + $item.Name; 
                        $trigger_details = getTriggerDetailsTable $item; 
                        $body += "<h2>Details</h2>$trigger_details<h2>Object Definition</h2>$definition"; 
                    }                     
                } 
                writeHtmlPage $title $title $body $page; 
            } 
        } 
    } 
} 
 
# Ścieżka gdzie dokumentacja zostanie wygenerowana
$filePath = "$env:USERPROFILE\database_documentation\"; 
New-Item -Path $filePath -ItemType directory -Force | Out-Null; 
# SQL SERVER dla którego generujemy dokumentacje
$sql_server = New-Object Microsoft.SqlServer.Management.Smo.Server $args[0]; 
# IsSystemObject nie są zwracane defaultowo
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.Table], "IsSystemObject"); 
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.View], "IsSystemObject"); 
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.StoredProcedure], "IsSystemObject"); 
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.Trigger], "IsSystemObject"); 
 
# Pobierz bazy danych na serwerze
$databases = getDatabases $sql_server; 
 
foreach ($db in $databases) 
{ 
    Write-Host "Started documenting " $db.Name; 
    # Oddzielna ścieżka dla każdej z baz danych
    New-Item -Path $($filePath + $db.Name) -ItemType directory -Force | Out-Null; 
	$imagesFilePath = $filePath + $db.Name + "\images\";
	New-Item -Path $imagesFilePath -ItemType directory -Force | Out-Null; 

 
    # Stwórz stronę dla bazy danych
    $db_page = $filePath + $($db.Name) + "\index.html"; 
    $body = "<ul> 
                <li><a href='Schemata/index.html'>Schemata</a></li> 
                <li><a href='Tables/index.html'>Tables</a></li> 
                <li><a href='Views/index.html'>Views</a></li> 
                <li><a href='Stored Procedures/index.html'>Stored Procedures</a></li> 
                <li><a href='Functions/index.html'>Functions</a></li> 
                <li><a href='Triggers/index.html'>Triggers</a></li> 
            </ul>"; 
    writeHtmlPage $db $db $body $db_page; 
         
    # Pobierz schematy dla tej bazy
    $schemata = getDatabaseSchemata $sql_server $db; 
    createObjectTypePages "Schemata" $schemata $filePath $db $imagesFilePath; 
    Write-Host "Documented schemata"; 
    # Pobierz tabele dla tej bazy
    $tables = getDatabaseTables $sql_server $db; 
    createObjectTypePages "Tables" $tables $filePath $db $imagesFilePath; 
    Write-Host "Documented tables"; 
    # Pobierz widoki dla tej bazy
    $views = getDatabaseViews $sql_server $db; 
    createObjectTypePages "Views" $views $filePath $db $imagesFilePath; 
    Write-Host "Documented views"; 
    # Pobierz procedury dla tej bazy
    $procs = getDatabaseStoredProcedures $sql_server $db; 
    createObjectTypePages "Stored Procedures" $procs $filePath $db $imagesFilePath; 
    Write-Host "Documented stored procedures"; 
    # Pobierz funkcje dla tej bazy
    $functions = getDatabaseFunctions $sql_server $db; 
    createObjectTypePages "Functions" $functions $filePath $db $imagesFilePath; 
    Write-Host "Documented functions"; 
    # Pobierz triggery dla tej bazy 
    $triggers = getDatabaseTriggers $sql_server $db; 
    createObjectTypePages "Triggers" $triggers $filePath $db $imagesFilePath; 
    Write-Host "Documented triggers"; 
    Write-Host "Finished documenting " $db.Name; 
}