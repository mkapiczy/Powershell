# Load needed assemblies 
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | Out-Null; 
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMOExtended")| Out-Null; 


#######################
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

#######################
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

#######################
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

#######################
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
 
# Simple to function to write html pages 
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
 
# Return all user databases on a sql server 
function getDatabases 
{ 
    param ($sql_server); 
    $databases = $sql_server.Databases | Where-Object {$_.IsSystemObject -eq $false}; 
    return $databases; 
} 
 
# Get all schemata in a database 
function getDatabaseSchemata 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $schemata = $sql_server.Databases[$db_name].Schemas; 
    return $schemata; 
} 
 
# Get all tables in a database 
function getDatabaseTables 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $tables = $sql_server.Databases[$db_name].Tables | Where-Object {$_.IsSystemObject -eq $false}; 
    return $tables; 
} 
 
# Get all stored procedures in a database 
function getDatabaseStoredProcedures 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $procs = $sql_server.Databases[$db_name].StoredProcedures | Where-Object {$_.IsSystemObject -eq $false}; 
    return $procs; 
} 
 
# Get all user defined functions in a database 
function getDatabaseFunctions 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $functions = $sql_server.Databases[$db_name].UserDefinedFunctions | Where-Object {$_.IsSystemObject -eq $false}; 
    return $functions; 
} 
 
# Get all views in a database 
function getDatabaseViews 
{ 
    param ($sql_server, $database); 
    $db_name = $database.Name; 
    $views = $sql_server.Databases[$db_name].Views | Where-Object {$_.IsSystemObject -eq $false}; 
    return $views; 
} 
 
# Get all table triggers in a database 
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
 
# This function builds a list of links for database object types 
function buildLinkList 
{ 
    param ($array, $path); 
    $output = "<ul>"; 
    foreach($item in $array) 
    { 
        if($item.IsSystemObject -eq $false) # Exclude system objects 
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
 
# Return the DDL for a given database object 
function getObjectDefinition 
{ 
    param ($item); 
    $definition = ""; 
    # Schemas don't like our scripting options 
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
 
# This function will get the comments on objects 
# MS calls these MS_Descriptionn when you add them through SSMS 
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
 
# Gets the parameters for a Stored Procedure 
function getProcParameterTable 
{ 
    param ($proc); 
    $proc_params = $proc.Parameters; 
    $prms = $proc_params | ConvertTo-Html -Fragment -Property Name, DataType, DefaultValue, IsOutputParameter; 
    return $prms; 
} 
 
# Returns a html table of column details for a db table 
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

function getTableUML
{
	param ($table, $imagesFilePath); 
	$serverName = 'localhost';$databaseName = $db.Name; $schema='dbo';$name=$table.Name
	$meta = Get-SqlMeta $serverName $databaseName $schema $name
    #$meta[0] | Write-Host
	$yUML = (ConvertTo-yUML $meta[0])
	Get-yUMLDiagram $yUML $table $imagesFilePath -download
    
}
 
# Returns a html table containing trigger details 
function getTriggerDetailsTable 
{ 
    param ($trigger); 
    $trigger_details = $trigger | ConvertTo-Html -Fragment -Property IsEnabled, CreateDate, DateLastModified, Delete, DeleteOrder, Insert, InsertOrder, Update, UpdateOrder; 
    return $trigger_details; 
} 
 
# This function creates all the html pages for our database objects 
function createObjectTypePages 
{ 
    param ($objectName, $objectArray, $filePath, $db, $imagesFilePath); 
    New-Item -Path $($filePath + $db.Name + "\$objectName") -ItemType directory -Force | Out-Null; 
    # Create index page for object type 
    $page = $filePath + $($db.Name) + "\$objectName\index.html"; 
    $list = buildLinkList $objectArray ""; 
    if($objectArray -eq $null) 
    { 
        $list = "No $objectName in $db"; 
    } 
    writeHtmlPage $objectName $objectName $list $page; 
    # Individual object pages 
    if($objectArray.Count -gt 0) 
    { 
        foreach ($item in $objectArray) 
        { 
            if($item.IsSystemObject -eq $false) # Exclude system objects 
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
 
# Root directory where the html documentation will be generated 
$filePath = "$env:USERPROFILE\database_documentation\"; 
New-Item -Path $filePath -ItemType directory -Force | Out-Null; 
# sql server that hosts the databases we wish to document 
$sql_server = New-Object Microsoft.SqlServer.Management.Smo.Server localhost; 
# IsSystemObject not returned by default so ask SMO for it 
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.Table], "IsSystemObject"); 
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.View], "IsSystemObject"); 
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.StoredProcedure], "IsSystemObject"); 
$sql_server.SetDefaultInitFields([Microsoft.SqlServer.Management.SMO.Trigger], "IsSystemObject"); 
 
# Get databases on our server 
$databases = getDatabases $sql_server; 
 
foreach ($db in $databases) 
{ 
    Write-Host "Started documenting " $db.Name; 
    # Directory for each database to keep everything tidy 
    New-Item -Path $($filePath + $db.Name) -ItemType directory -Force | Out-Null; 
	$imagesFilePath = $filePath + $db.Name + "\images\";
	New-Item -Path $imagesFilePath -ItemType directory -Force | Out-Null; 

 
    # Make a page for the database 
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
         
    # Get schemata for the current database 
    $schemata = getDatabaseSchemata $sql_server $db; 
    createObjectTypePages "Schemata" $schemata $filePath $db $imagesFilePath; 
    Write-Host "Documented schemata"; 
    # Get tables for the current database 
    $tables = getDatabaseTables $sql_server $db; 
    createObjectTypePages "Tables" $tables $filePath $db $imagesFilePath; 
    Write-Host "Documented tables"; 
    # Get views for the current database 
    $views = getDatabaseViews $sql_server $db; 
    createObjectTypePages "Views" $views $filePath $db $imagesFilePath; 
    Write-Host "Documented views"; 
    # Get procs for the current database 
    $procs = getDatabaseStoredProcedures $sql_server $db; 
    createObjectTypePages "Stored Procedures" $procs $filePath $db $imagesFilePath; 
    Write-Host "Documented stored procedures"; 
    # Get functions for the current database 
    $functions = getDatabaseFunctions $sql_server $db; 
    createObjectTypePages "Functions" $functions $filePath $db $imagesFilePath; 
    Write-Host "Documented functions"; 
    # Get triggers for the current database 
    $triggers = getDatabaseTriggers $sql_server $db; 
    createObjectTypePages "Triggers" $triggers $filePath $db $imagesFilePath; 
    Write-Host "Documented triggers"; 
    Write-Host "Finished documenting " $db.Name; 
}