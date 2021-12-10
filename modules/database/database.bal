// Copyright 2021 University of Stuttgart
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import ballerina/io;
import ballerina/time;
import ballerina/sql;
import ballerina/mime;
import ballerinax/java.jdbc;

sql:ConnectionPool sqlitePool = {
    maxOpenConnections: 5,
    maxConnectionLifeTime: 1800,
    minIdleConnections: 0
};

# Either "sqlite" or "mariadb"
configurable string dbType = "sqlite";

// sqlite specific config
# File Path to the sqlite db
configurable string dbPath = "qhana-backend.db";

// mariadb specific config
# Hostname + port for mariadb db
configurable string dbHost = "localhost:3306";
# DB name for mariadb db
configurable string dbName = "QHAnaExperiments";
# DB user for mariadb db
configurable string dbUser = "QHAna";
# DB password for mariadb db
configurable string dbPassword = "";

function initClient() returns jdbc:Client|error {
    if dbType == "sqlite" {
        return new jdbc:Client(string `jdbc:sqlite:${dbPath}`, connectionPool = sqlitePool);
    } else if dbType == "mariadb" || dbType == "mysql" {
        string connection = string `jdbc:mariadb://${dbHost}/${dbName}?user=${dbUser}`;
        if dbPassword != "" {
            string passwordPart = string `&password=${dbPassword}`;
            connection = connection + passwordPart;
        }
        io:println(connection);
        return new jdbc:Client(connection);
    } else {
        return error(string `Db type ${dbType} is unknownn!`);
    }
}

# always provide an initialized dummy jdbc client to circumvent null handling in every method
final jdbc:Client experimentDB = check initClient();

type RowCount record {
    int rowCount;
};

public type PluginEndpoint record {|
    string url;
    string 'type = "PluginRunner";
|};

public type PluginEndpointFull record {|
    readonly int id;
    *PluginEndpoint;
|};

// Experiments /////////////////////////////////////////////////////////////////

# Record containing the pure data of an Experiment.
#
# + name - The experiment name
# + description - The experiment description
public type Experiment record {|
    string name;
    string description = "";
|};

# Record containing the experiment data and the database ID of the Experiment
#
# + experimentId - The database id of the record
public type ExperimentFull record {|
    readonly int experimentId;
    *Experiment;
|};

// Data ////////////////////////////////////////////////////////////////////////

public type ExperimentDataReference record {|
    string name;
    int 'version;
|};

public type ExperimentData record {|
    *ExperimentDataReference;
    string location;
    string 'type;
    string contentType;
|};

public type ExperimentDataFull record {|
    readonly int dataId;
    readonly int experimentId;
    *ExperimentData;
|};

// Timeline ////////////////////////////////////////////////////////////////////

public type TimelineSubstep record {|
    string substepId;
    int substepNr;
    string href;
    string? hrefUi;
    int cleared;
|};

public type TimelineStepRef record {|
    readonly int experimentId;
    readonly int sequence;
|};

public type TimelineStepDbRef record {|
    readonly int stepId;
|};

public type TimelineStep record {|
    time:Utc 'start;
    time:Utc? end = ();
    string status = "PENDING";
    string resultQuality = "UNKNOWN";
    string? resultLog = ();
    string processorName;
    string? processorVersion = ();
    string? processorLocation = ();
    string parameters?; // optional for small requests
    string? parametersContentType = ();
    string? parametersDescriptionLocation = ();
    string notes?; // optional for small requests
    int? progressValue = ();
    int? progressStart = ();
    int? progressTarget = ();
    string? progressUnit = (); // TODO how are these set? -> change needed
|};

public type TimelineStepFull record {|
    *TimelineStepDbRef;
    *TimelineStepRef;
    *TimelineStep;
|};

public type TimelineStepSQL record {|
    *TimelineStepDbRef;
    *TimelineStepRef;
    string|time:Utc 'start;
    string|time:Utc|() end = ();
    string status = "PENDING";
    string resultQuality = "UNKNOWN";
    string? resultLog = ();
    string processorName;
    string? processorVersion = ();
    string? processorLocation = ();
    string parameters?; // optional for small requests
    string? parametersContentType = ();
    string? parametersDescriptionLocation = ();
    string notes?; // optional for small requests
    int? progressValue = ();
    int? progressStart = ();
    int? progressTarget = ();
    string? progressUnit = (); // TODO how are these set? -> change needed
|};

public type TimelineStepWithParams record {|
    *TimelineStepFull;
    string parameters;
|};

public type TimelineSubstepSQL record {|
    int stepId;
    int substepNr;
    string substepId;
    string href;
    string? hrefUi;
    int cleared;
|}; // TODO: how to add those into step???

// Timeline to Data links //////////////////////////////////////////////////////

public type StepToData record {|
    readonly int stepId;
    readonly int dataId;
    string relationType;
|};

public isolated transactional function getPluginEndpointsCount() returns int|error {
    stream<RowCount, sql:Error?> result = experimentDB->query(`SELECT count(*) AS rowCount FROM PluginEndpoints;`);
    var count = result.next();
    check result.close();
    if count is error {
        return count;
    }
    if count is record {RowCount value;} {
        return count.value.rowCount;
    } else {
        // should never happen based on the sql query
        return error("Could not determine the plugin endpoint count!");
    }
}

public isolated transactional function getPluginEndpoints() returns PluginEndpointFull[]|error {
    stream<PluginEndpointFull, sql:Error?> endpoints = experimentDB->query(
        `SELECT id, url, type FROM PluginEndpoints ORDER BY type, url;`
    );

    PluginEndpointFull[]? endpointList = check from var endpoint in endpoints
        select endpoint;

    check endpoints.close();

    if endpointList != () {
        return endpointList;
    }

    return [];
}

public isolated transactional function getPluginEndpoint(int endpointId) returns PluginEndpointFull|error {
    stream<PluginEndpointFull, sql:Error?> endpoints = experimentDB->query(
        `SELECT id, url, type FROM PluginEndpoints WHERE id=${endpointId};`
    );

    var endpoint = endpoints.next();
    check endpoints.close();

    if !(endpoint is sql:Error) && (endpoint != ()) {
        return endpoint.value;
    }

    return error(string `Endpoint with id ${endpointId} was not found!`);
}

public isolated transactional function addPluginEndpoint(*PluginEndpoint endpoint) returns PluginEndpointFull|error {
    var result = check experimentDB->execute(
        `INSERT INTO PluginEndpoints (url, type) VALUES (${endpoint.url}, ${endpoint.'type});`
    );

    var endpointId = result.lastInsertId;

    if !(endpointId is int) {
        return error("Could not parse last insert id for endpoint.");
    } else {
        return {
            id: endpointId,
            url: endpoint.url,
            'type: endpoint.'type
        };
    }
}

public isolated transactional function editPluginEndpoint(int endpointId, string 'type) returns PluginEndpointFull|error {
    var result = check experimentDB->execute(
        `UPDATE PluginEndpoints SET type=${'type} WHERE id=${endpointId};`
    );

    return getPluginEndpoint(endpointId);
}

public isolated transactional function deletePluginEndpoint(int endpointId) returns error? {
    var result = experimentDB->execute(
        `DELETE FROM PluginEndpoints WHERE id=${endpointId};`
    );

    if result is error {
        return result;
    } else {
        return;
    }
}

////////////////////////////////////////////////////////////////////////////////
// Experiments /////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

# Return the number of experiments in the database.
#
# + return - The number of experiments or the encountered error
public isolated transactional function getExperimentCount() returns int|error {
    stream<RowCount, sql:Error?> result = experimentDB->query(`SELECT count(*) AS rowCount FROM Experiment;`);
    var count = result.next();
    check result.close();
    if count is error {
        return count;
    }
    if count is record {RowCount value;} {
        return count.value.rowCount;
    } else {
        // should never happen based on the sql query
        return error("Could not determine the experiment count!");
    }
}

# Get the list of experiments from the database.
#
# + 'limit - The maximum number of experiments fetched in one call (default: `100`)
# + offset - The offset applied to the sql query (default: `0`)
# + return - The list of experiments or the encountered error
public isolated transactional function getExperiments(int 'limit = 100, int offset = 0) returns ExperimentFull[]|error {
    stream<ExperimentFull, sql:Error?> experiments = experimentDB->query(
        `SELECT experimentId, name, description FROM Experiment ORDER BY name ASC LIMIT ${'limit} OFFSET ${offset};`
    );

    ExperimentFull[]? experimentList = check from var experiment in experiments
        select experiment;

    check experiments.close();

    if experimentList != () {
        return experimentList;
    }

    return [];
}

# Get a single experiment from the database.
#
# + experimentId - The database id of the experiment to fetch
# + return - The experiment or the encountered error
public isolated transactional function getExperiment(int experimentId) returns ExperimentFull|error {
    stream<ExperimentFull, sql:Error?> experiments = experimentDB->query(
        `SELECT experimentId, name, description FROM Experiment WHERE experimentId = ${experimentId} LIMIT 1;`
    );

    var experiment = experiments.next();
    check experiments.close();

    if !(experiment is sql:Error) && (experiment != ()) {
        return experiment.value;
    }

    return error(string `Experiment ${experimentId} was not found!`);
}

# Create a new experiment in the database.
#
# + experiment - The data for the new experiment
# + return - The experiment data including the database id or the encountered error
public isolated transactional function createExperiment(*Experiment experiment) returns ExperimentFull|error {
    ExperimentFull? result = ();

    stream<Experiment, sql:Error?> experiments;
    var insertResult = check experimentDB->execute(
        `INSERT INTO Experiment (name, description) VALUES (${experiment.name}, ${experiment.description});`
    );

    // extract experiment id and build full experiment data
    var experimentId = insertResult.lastInsertId;
    if experimentId is string {
        fail error("Expected integer id but got a string!");
    } else if experimentId == () {
        fail error("Expected the experiment id back but got nothing!");
    } else {
        result = {experimentId: experimentId, name: experiment.name, description: experiment.description};
    }

    if result == () {
        // this should logically never happen but is included for the compiler
        return error("Experiment was empty after transaction comitted.");
    } else {
        return result;
    }
}

# Update an existing experiment in place in the database.
#
# + experimentId - The database id of the experiment to update
# + experiment - The updated data for the existing experiment
# + return - The updated experiment data including the database id or the encountered error
public isolated transactional function updateExperiment(int experimentId, *Experiment experiment) returns ExperimentFull|error {
    stream<Experiment, sql:Error?> experiments;
    var test = check experimentDB->execute(
        `UPDATE Experiment SET name=${experiment.name}, description=${experiment.description} WHERE experimentId = ${experimentId};`
    );
    io:println(test);
    return {experimentId, name: experiment.name, description: experiment.description};
}

////////////////////////////////////////////////////////////////////////////////
// Data ////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

# Get the number of data entries for a specific experiment.
#
# + experimentId - The experiment id
# + all - If true count all experiment data including old version, if false count only the newest verwions (e.g. distinct data names)
# + return - The count or the encountered error
public isolated transactional function getExperimentDataCount(int experimentId, boolean all = true) returns int|error {
    stream<RowCount, sql:Error?> result;
    if all {
        result = experimentDB->query(`SELECT count(*) AS rowCount FROM ExperimentData WHERE experimentId = ${experimentId};`);
    } else {
        result = experimentDB->query(`SELECT count(DISTINCT name) AS rowCount FROM ExperimentData WHERE experimentId = ${experimentId};`);
    }
    var count = result.next();

    check result.close();

    if count is record {RowCount value;} {
        return count.value.rowCount;
    } else if count is error {
        return count;
    } else {
        // should never happen based on the sql query
        return error("Could not determine the experiment count!");
    }
}

public isolated transactional function getDataList(int experimentId, boolean all = true, int 'limit = 100, int offset = 0) returns ExperimentDataFull[]|error {
    var baseQuery = `SELECT dataId, experimentId, name, version, location, type, contentType 
                     FROM ExperimentData WHERE experimentId=${experimentId} `;
    var baseQuerySuffix = `ORDER BY name ASC, version DESC 
                           LIMIT ${'limit} OFFSET ${offset};`;

    stream<ExperimentDataFull, sql:Error?> experimentData;
    if all {
        experimentData = experimentDB->query(check new ConcatQuery(baseQuery, baseQuerySuffix));
    } else {
        var extraFilter = `AND version=(SELECT MAX(t2.version)
                                FROM ExperimentData AS t2 
                                WHERE ExperimentData.name=t2.name AND t2.experimentId=${experimentId}) `;
        experimentData = experimentDB->query(check new ConcatQuery(baseQuery, extraFilter, baseQuerySuffix));
    }

    ExperimentDataFull[]? experimentDataList = check from var data in experimentData
        select data;

    check experimentData.close();

    if experimentDataList != () {
        return experimentDataList;
    }

    return [];
}

public isolated transactional function getData(int experimentId, string name, string|int|() 'version) returns ExperimentDataFull|error {
    var baseQuery = `SELECT dataId, experimentId, name, version, location, type, contentType 
                     FROM ExperimentData WHERE experimentId=${experimentId} AND name=${name}`;
    stream<ExperimentDataFull, sql:Error?> data;

    if 'version == () || 'version == "latest" {
        // get latest version with order by descending and limit to one
        data = experimentDB->query(check new ConcatQuery(baseQuery, ` ORDER BY version DESC LIMIT 1;`));
    } else {
        // get a specific version with order by descending and limit to one
        data = experimentDB->query(check new ConcatQuery(baseQuery, ` AND version=${'version} LIMIT 1;`));
    }

    var result = data.next();
    check data.close();

    if !(result is sql:Error) && (result != ()) {
        return result.value;
    }

    return error(string `Experiment data with experimentId: ${experimentId}, name: ${name} and version: ${'version == () ? "latest" : 'version} was not found!`);
}

public isolated transactional function getProducingStepOfData(int|ExperimentDataFull data) returns int|error {
    stream<record {int producingStep;}, sql:Error?> step;

    final var dataId = (data is int) ? data : data.dataId;
    step = experimentDB->query(
        `SELECT sequence AS producingStep FROM StepData JOIN TimelineStep ON StepData.stepId = TimelineStep.stepId 
         WHERE relationType = "output" and dataId = ${dataId} LIMIT 1;`
    );

    var result = step.next();
    check step.close();

    if !(result is sql:Error) && (result != ()) {
        return result.value.producingStep;
    }

    return error(string `Experiment data with dataId: ${dataId} has no producing step!`);
}

public isolated transactional function getStepsUsingData(int|ExperimentDataFull data) returns int[]|error {
    stream<record {int sequence;}, sql:Error?> steps;

    final var dataId = (data is int) ? data : data.dataId;
    steps = experimentDB->query(
        `SELECT sequence FROM StepData JOIN TimelineStep ON StepData.stepId = TimelineStep.stepId 
         WHERE relationType = "input" and dataId = ${dataId} LIMIT 1;`
    );

    int[]|error? inputForSteps = from var step in steps
        select step.sequence;

    check steps.close();

    if inputForSteps is () {
        return [];
    } else if !(inputForSteps is error) {
        return inputForSteps;
    }

    return error(string `Experiment data with dataId: ${dataId} has no producing step!`);
}

////////////////////////////////////////////////////////////////////////////////
// Timeline ////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

public isolated transactional function getTimelineStepCount(int experimentId) returns int|error {
    stream<RowCount, sql:Error?> result = experimentDB->query(
        `SELECT count(*) AS rowCount FROM TimelineStep WHERE experimentId = ${experimentId};`
    );

    var count = result.next();
    check result.close();

    if count is record {RowCount value;} {
        return count.value.rowCount;
    } else if count is error {
        return count;
    } else {
        // should never happen based on the sql query
        return error("Could not determine the experiment count!");
    }
}

public isolated transactional function getTimelineSubstepList(int stepId) returns TimelineSubstep[]|()|error {
    object:RawTemplate[] query = [`SELECT stepId, substepNr, substepId, href, hrefUi, cleared`];

    query.push(`FROM TimelineSubstep WHERE stepId=${stepId} ORDER BY substepNr ASC;`);

    stream<TimelineSubstepSQL, sql:Error?> timelineSubsteps = experimentDB->query(check new ConcatQuery(...query));

    (TimelineSubstepSQL)[]|error|() tempList = from var substep in timelineSubsteps
        select substep;

    check timelineSubsteps.close();

    TimelineSubstep[] substepList = [];
    if tempList is error {
        return tempList;
    } else if tempList is () {
        return [];
    } else {
        // convert timestamps to correct utc type if timestamps come from sqlite
        foreach var tempSubstep in tempList {
            TimelineSubstep substep = {
                substepId: tempSubstep.substepId,
                substepNr: tempSubstep.substepNr,
                href: tempSubstep.href,
                hrefUi: tempSubstep.hrefUi,
                cleared: tempSubstep.cleared
            };
            substepList.push(substep);
        }
    }
    return substepList;
}

public isolated transactional function castToTimelineStepFull(TimelineStepSQL step) returns TimelineStepFull|error {
    var startString = step.'start; // needed for correct type narrowing
    if startString is string {
        var utcString = startString; // needed for correct type narrowing
        if !startString.endsWith("Z") {
            utcString += ".00Z";
        }
        time:Utc 'start = check time:utcFromString(utcString);
        step.'start = 'start;
    }
    var endString = step.end; // needed for correct type narrowing
    if endString is string {
        var utcString = endString; // needed for correct type narrowing
        if !endString.endsWith("Z") {
            utcString += ".00Z";
        }
        time:Utc end = check time:utcFromString(utcString);
        step.end = end;
    }
    return step.cloneWithType();
}

public isolated transactional function getTimelineStepList(int experimentId, boolean allAttributes = false, int 'limit = 100, int offset = 0) returns TimelineStepFull[]|error {
    object:RawTemplate[] query = [`SELECT stepId, experimentId, sequence, `];

    if dbType == "sqlite" {
        query.push(`cast(start as TEXT) AS start, cast(end as TEXT) AS end, `);
    } else {
        query.push(`DATE_FORMAT(start, '%Y-%m-%dT%H:%i:%S') AS start, DATE_FORMAT(end, '%Y-%m-%dT%H:%i:%S') AS end, `);
    }

    query.push(`status, processorName, processorVersion, processorLocation, parametersDescriptionLocation`);

    if allAttributes {
        query.push(`, resultQuality, resultLog, parameters, parametersContentType, notes `);
    } else {
        query.push(`, NULL AS resultLog `);
    }

    query.push(`FROM TimelineStep WHERE experimentId=${experimentId} ORDER BY sequence ASC LIMIT ${'limit} OFFSET ${offset};`);

    stream<TimelineStepSQL, sql:Error?> timelineSteps = experimentDB->query(check new ConcatQuery(...query));

    (TimelineStepSQL|TimelineStepFull)[]|error|() tempList = from var step in timelineSteps
        select step;

    // TODO: retrieve associated substeps for each step

    check timelineSteps.close();

    TimelineStepFull[] stepList = [];
    if tempList is error {
        return tempList;
    } else if tempList is () {
        return [];
    } else {
        // convert timestamps to correct utc type if timestamps come from sqlite
        foreach var step in tempList {
            TimelineStepFull stepFull = check castToTimelineStepFull(step);
            stepList.push(stepFull);
        }
    }

    return stepList;
}

public isolated transactional function createTimelineStep(
        int experimentId,
        string processorName,
        string? processorVersion = (),
        string? processorLocation = (),
        string? parameters = (),
        string? parametersContentType = mime:APPLICATION_FORM_URLENCODED,
        string? parametersDescriptionLocation = ()
    ) returns TimelineStepWithParams|error {
    TimelineStepWithParams? result = ();

    if parameters == () && parametersContentType == () {
        return error("When parameters are given the parameters content type is required!");
    }

    stream<TimelineStepSQL, sql:Error?> createdStep;
    sql:ParameterizedQuery currentTime = `strftime('%Y-%m-%dT%H:%M:%S', 'now')`;
    if dbType != "sqlite" {
        currentTime = `DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%dT%H:%i:%S')`;
    }
    var insertResult = check experimentDB->execute(
        check new ConcatQuery(
            `INSERT INTO TimelineStep (experimentId, sequence, start, end, processorName, processorVersion, processorLocation, parameters, parametersContentType, parametersDescriptionLocation) 
            VALUES (${experimentId}, (SELECT sequence from (SELECT count(*)+1 AS sequence FROM TimelineStep WHERE experimentId = ${experimentId}) subquery), `,
            currentTime,
            `, NULL, ${processorName}, ${processorVersion}, ${processorLocation}, ${parameters}, ${parametersContentType}, ${parametersDescriptionLocation});`
        )
    );

    // extract experiment id and build full experiment data
    var stepId = insertResult.lastInsertId;
    if stepId is string {
        fail error("Expected integer id but got a string!");
    } else if stepId == () {
        fail error("Expected the experiment id back but got nothing!");
    } else {
        int s = check stepId.ensureType();
        return getTimelineStep(stepId = s);
    }
}

public isolated transactional function getTimelineStep(int? experimentId = (), int? sequence = (), int? stepId = ()) returns TimelineStepWithParams|error {
    var baseQuery = `SELECT stepId, experimentId, sequence, cast(start as TEXT) AS start, cast(end as TEXT) AS end, status, resultQuality, resultLog, processorName, processorVersion, processorLocation, parametersDescriptionLocation, parameters, parametersContentType
                     FROM TimelineStep `;
    if dbType != "sqlite" {
        baseQuery = `SELECT stepId, experimentId, sequence, DATE_FORMAT(start, '%Y-%m-%dT%H:%i:%S') AS start, DATE_FORMAT(end, '%Y-%m-%dT%H:%i:%S') AS end, status, resultQuality, resultLog, processorName, processorVersion, processorLocation, parametersDescriptionLocation, parameters, parametersContentType
                     FROM TimelineStep `;
    }

    stream<TimelineStepSQL, sql:Error?> timelineStep;

    TimelineStepRef|TimelineStepDbRef ref;

    if experimentId == () && sequence == () && stepId == () {
        return error("Must provide either experimentId and sequence or the stepId!");
    } else if experimentId != () && sequence != () && stepId != () {
        return error("Must not provide all parameters at the same time!");
    } else if experimentId != () && sequence != () {
        timelineStep = experimentDB->query(
            check new ConcatQuery(baseQuery, `WHERE experimentId=${experimentId} AND sequence=${sequence} LIMIT 1;`)
        );
        ref = {experimentId: experimentId, sequence: sequence};
    } else if stepId != () {
        timelineStep = experimentDB->query(check new ConcatQuery(baseQuery, `WHERE stepId=${stepId} LIMIT 1;`));
        ref = {stepId: stepId};
    } else {
        return error("Must provide either experimentId and sequence or the stepId!");
    }

    var result = timelineStep.next();
    check timelineStep.close();

    if !(result is sql:Error) && (result != ()) {
        TimelineStepFull|error stepFull = castToTimelineStepFull(result.value);
        if stepFull is error {
            return error(string `The Timeline step with reference ${ref.toString()} could not be read from the database!`, stepFull);
        } else {
            TimelineStepWithParams|error step = stepFull.cloneWithType(TimelineStepWithParams);
            if step is error {
                return error(string `The Timeline step with reference ${ref.toString()} did not have the required parameters field!`, step);
            }
            return step;
        }
    }

    return error(string `Timeline step with reference ${ref.toString()} was not found!`);
}

public isolated transactional function updateTimelineStepStatus(int|TimelineStepFull step, string status, string? resultLog) returns error? {
    var stepId = step is int ? step : step.stepId;

    sql:ParameterizedQuery currentTime = `strftime('%Y-%m-%dT%H:%M:%S', 'now')`;
    if dbType != "sqlite" {
        currentTime = `DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%dT%H:%i:%S')`;
    }

    _ = check experimentDB->execute(
        check new ConcatQuery(
            `UPDATE TimelineStep 
                SET 
                    end=`, currentTime, `, 
                    status=${status},
                    resultLog=${resultLog}
                WHERE stepId = ${stepId} AND end IS NULL;`
        )
    );
}

public isolated transactional function getStepInputData(int|TimelineStepFull step) returns ExperimentDataReference[]|error {
    stream<ExperimentDataReference, sql:Error?> inputData;

    var stepId = step is int ? step : step.stepId;
    inputData = experimentDB->query(
        `SELECT name, version FROM StepData JOIN ExperimentData ON StepData.dataId = ExperimentData.dataId 
         WHERE relationType = "input" and stepId = ${stepId};`
    );

    ExperimentDataReference[]|error? inputDataList = from var row in inputData
        select row;
    check inputData.close();

    if inputDataList is () {
        return [];
    } else if !(inputDataList is error) {
        return inputDataList;
    }

    return error(string `Failed to retrieve input data for experiment step with stepId ${stepId}!`);
}

public isolated transactional function saveTimelineStepInputData(int stepId, int experimentId, ExperimentDataReference[] inputData) returns error? {
    foreach var data in inputData {
        var experimentData = check getData(experimentId, data.name, data.'version);
        _ = check experimentDB->execute(`INSERT INTO StepData (stepId, dataId, relationType) VALUES (${stepId}, ${experimentData.dataId}, ${"input"});`);
    }
}

public isolated transactional function getStepOutputData(int|TimelineStepFull step) returns ExperimentDataReference[]|error {
    stream<ExperimentDataReference, sql:Error?> outputData;

    var stepId = step is int ? step : step.stepId;
    outputData = experimentDB->query(
        `SELECT name, version FROM StepData JOIN ExperimentData ON StepData.dataId = ExperimentData.dataId 
         WHERE relationType = "output" and stepId = ${stepId};`
    );

    ExperimentDataReference[]|error? outputDataList = from var row in outputData
        select row;
    check outputData.close();

    if outputDataList is () {
        return [];
    } else if !(outputDataList is error) {
        return outputDataList;
    }

    return error(string `Failed to retrieve output data for experiment step with stepId ${stepId}!`);
}

public isolated transactional function saveTimelineStepOutputData(int stepId, int experimentId, ExperimentData[] outputData) returns error? {
    var baseQuery = `INSERT INTO ExperimentData (experimentId, name, version, location, type, contentType) VALUES `;
    var dataQuery = from var d in outputData
        select `(${experimentId}, ${d.name}, (SELECT version FROM (SELECT count(*) + 1 AS version FROM ExperimentData WHERE name = ${d.name}) subquery), ${d.location}, ${d.'type}, ${d.contentType})`;

    foreach var insertData in dataQuery {
        var result = check experimentDB->execute(check new ConcatQuery(baseQuery, insertData));
        var dataId = result.lastInsertId;
        _ = check experimentDB->execute(`INSERT INTO StepData (stepId, dataId, relationType) VALUES (${stepId}, ${dataId}, ${"output"});`);
    }
}

public isolated transactional function getTimelineStepNotes(int experimentId, int sequence) returns string|error {
    stream<record {|string? notes;|}, sql:Error?> note = experimentDB->query(
        `SELECT notes
         FROM TimelineStep WHERE experimentId=${experimentId} AND sequence=${sequence} LIMIT 1;`
    );

    var result = note.next();
    check note.close();

    if !(result is sql:Error) && (result != ()) {
        var notesText = result.value.notes;
        if notesText == () {
            return "";
        } else {
            return notesText;
        }
    }

    return error(string `Notes for timeline step with experimentId: ${experimentId} and sequence: ${sequence} were not found!`);
}

public isolated transactional function updateTimelineStepNotes(int experimentId, int sequence, string notes) returns error? {
    stream<Experiment, sql:Error?> experiments;
    var test = check experimentDB->execute(
        `UPDATE TimelineStep SET notes=${notes} WHERE experimentId = ${experimentId} AND sequence=${sequence};`
    );
    io:println(test);
}

public isolated transactional function updateTimelineStepResultQuality(int experimentId, int sequence, string resultQuality) returns error? {
    stream<Experiment, sql:Error?> experiments;
    var test = check experimentDB->execute(
        `UPDATE TimelineStep SET resultQuality=${resultQuality} WHERE experimentId = ${experimentId} AND sequence=${sequence};`
    );
    io:println(test);
}

public isolated transactional function getTimelineStepsWithResultWatchers() returns int[]|error {
    stream<record {int stepId;}, sql:Error?> stepWatchers = experimentDB->query(
        `SELECT stepId FROM ResultWatchers;`
    );
    int[]|error|() result = from var watcher in stepWatchers
        select watcher.stepId;
    check stepWatchers.close();

    if result is () {
        return [];
    } else {
        return result;
    }
}

public isolated transactional function createTimelineStepResultWatcher(int stepId, string resultEndpoint) returns error? {
    if resultEndpoint == "" {
        return error("Result endpoint cannot be empty!");
    }
    var insertResult = check experimentDB->execute(
        `INSERT INTO ResultWatchers (stepId, resultEndpoint) 
         VALUES (${stepId}, ${resultEndpoint});`
    );
}

public isolated transactional function getTimelineStepResultEndpoint(int stepId) returns string?|error {
    stream<record {string resultEndpoint;}, sql:Error?> result = experimentDB->query(
        `SELECT resultEndpoint FROM ResultWatchers WHERE stepId = ${stepId};`
    );
    var first = result.next();
    check result.close();

    if first is record {record {string resultEndpoint;} value;} {
        return first.value.resultEndpoint;
    } else {
        return first;
    }
}

public isolated transactional function deleteTimelineStepResultWatcher(int stepId) returns error? {
    _ = check experimentDB->execute(
        `DELETE FROM ResultWatchers WHERE stepId = ${stepId};`
    );
}

public isolated transactional function getTimelineSubsteps(int stepId) returns TimelineSubstepSQL[]|error {
    stream<TimelineSubstepSQL, sql:Error?> substeps = experimentDB->query(
        `SELECT stepId, substepNr, substepId, href, hrefUi, cleared FROM TimelineSubstep WHERE stepId=${stepId};;`
    );
    TimelineSubstepSQL[]|error|() result = check from var substep in substeps
        select substep;
    check substeps.close();

    if result is () {
        return [];
    } else {
        return result;
    }
}

public isolated transactional function createTimelineSubstep(int stepId, string href, string? hrefUi, string? substepId) returns error? {
    if href == "" {
        return error("Href cannot be empty!");
    }
    //stepId"	INTEGER NOT NULL,
    //"substepNr"	INTEGER NOT NULL,
    //"substepId"	VARCHAR(500) NOT NULL,
    //"href"	TEXT NOT NULL,
    //"hrefUi"	TEXT,
    //"cleared"	INTEGER DEF
    int count = check experimentDB->queryRow(`SELECT count(*) FROM TimelineSubstep WHERE stepId=${stepId};`);
    count += 1;
    var insertResult = check experimentDB->execute(
        `INSERT INTO TimelineSubstep (stepId, substepNr, substepId, href, hrefUi, cleared) 
         VALUES (${stepId}, ${count}, ${substepId != () ? substepId : count.toString()}, ${href}, ${hrefUi});`
    );
}

