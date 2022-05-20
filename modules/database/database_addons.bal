// Copyright 2022 University of Stuttgart
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

import ballerina/sql;
import ballerina/io;
import ballerina/mime;

public type IdSQL record {|
    int id;
|};

# Get experiment info
#
# + experimentId - experiment id
# + return - experiment info
public isolated transactional function getExperimentInfo(int experimentId) returns Experiment|error {
    Experiment experimentInfo;
    stream<record {|string name; string description;|}, sql:Error?> experimentResult = experimentDB->query(`SELECT name, description FROM Experiment WHERE experimentId=${experimentId};`);
    var experiment = experimentResult.next();
    check experimentResult.close();

    if experiment is record {record {string name; string description;} value;} {
        return {name: experiment.value.name, description: experiment.value.description};
    } else {
        return error(string `[experimentId ${experimentId}] Query to Experiment table unsuccessful.`);
    }
}

# Clones an experiment in the database.
#
# + oldExperimentId - experiment id of the experiment that is to be cloned
# + return - The experiment data including the database id or the encountered error
public isolated transactional function cloneExperiment(int oldExperimentId) returns ExperimentFull|error {
    ExperimentFull? result = ();

    // clone experiment
    Experiment experimentInfo = check getExperimentInfo(oldExperimentId);
    var experimentInsertResult = check experimentDB->execute(
        `INSERT INTO Experiment (name, description) VALUES (${experimentInfo.name}, ${experimentInfo.description});`
    );

    // extract experiment id and build full experiment data
    var newExperimentId = experimentInsertResult.lastInsertId;
    if newExperimentId !is int {
        fail error("Expected integer id but got a string or Nil!");
    } else {
        result = {experimentId: newExperimentId, name: experimentInfo.name, description: experimentInfo.description};

        io:println(string `[experimentId ${oldExperimentId}] Cloned experiment has experimentId ${newExperimentId}`); // TODO: remove

        // map old experimentData ids to new (cloned) to avoid duplication
        map<int> oldDataIdToNewDataId = {};

        // clone timeline steps
        stream<record {|int stepId;|}, sql:Error?> timelineStepResult = experimentDB->query(`SELECT stepId FROM TimelineStep WHERE experimentId=${oldExperimentId};`);
        int[]|error|() timelineStepList = from var step in timelineStepResult
            select step.stepId;
        if timelineStepList !is error && timelineStepList !is () {
            int counter = 0;
            foreach var oldTimelineStepId in timelineStepList {
                counter += 1;
                _ = check cloneTimelineStepComplex(newExperimentId, oldExperimentId, oldTimelineStepId, oldDataIdToNewDataId);
            }
            io:println(string `[ExperimentId ${newExperimentId}] Cloned ${counter} TimelineSteps.`);
        }
        if result == () {
            // this should logically never happen but is included for the compiler
            return error("Experiment was empty after transaction comitted.");
        } else {
            return result;
        }
    }
}

# Clones an ExperimentData item. 
#
# Checks if item is already cloned (in mapping of old/new ids). If not the item is cloned and added to the mapping
#
# + oldDataIdToNewDataId - mutable mapping of old ExperimentData item ids to new experiment data ids to check if new experiment data needs to be created or not
# + dataId - id of old ExperimentData item that is to be cloned
# + newExperimentId - experiment id of the new (cloned) experiment
# + oldExperimentId - experiment id of the experiment that is being cloned
# + return - The new (cloned) ExperimentData id or the encountered error
public isolated transactional function cloneExperimentData(map<int> oldDataIdToNewDataId, int dataId, int newExperimentId, int oldExperimentId) returns int|error {
    // TODO: deep copy?
    int? clonedExperimentDataId = oldDataIdToNewDataId[dataId.toString()];
    if clonedExperimentDataId is () {
        // not cloned yet => clone experiment data 
        var experimentDataInsertResult = check experimentDB->execute(
            `INSERT INTO ExperimentData (experimentId, name, version, location, type, contentType) 
            SELECT ${newExperimentId}, name, version, location, type, contentType
            FROM ExperimentData
            WHERE experimentId = ${oldExperimentId} AND dataId = ${dataId};`
        );
        // add to mapping
        var newExperimentDataId = experimentDataInsertResult.lastInsertId;
        if newExperimentDataId is int {
            lock {
                oldDataIdToNewDataId[dataId.toString()] = newExperimentDataId;
            }
            io:println(string `[experimentId ${oldExperimentId}, dataId ${dataId}] Cloned ExperimentData. Cloned ExperimentData has dataId ${newExperimentDataId}.`); // TODO: remove
            return newExperimentDataId;
        } else {
            fail error("Expected the experimentData id back but got nothing or Nil!");
        }
    } else {
        return clonedExperimentDataId;
    }
}

# Clones a timeline step. 
#
# + newExperimentId - experiment id of the new (cloned) experiment
# + oldExperimentId - experiment id of the experiment that is being cloned
# + oldTimelineStepId - step id of (old) timeline step that is to be cloned
# + return - The new (cloned) timeline step id or the encountered error
public isolated transactional function cloneTimelineStepSimple(int newExperimentId, int oldExperimentId, int oldTimelineStepId) returns int|error {
    var timelineStepInsertResult = check experimentDB->execute(
        `INSERT INTO TimelineStep (experimentId, sequence, start, end, status, resultQuality, resultLog, processorName, processorVersion, processorLocation, parameters, parametersContentType, pStart, pTarget, pValue, pUnit, notes)
        SELECT ${newExperimentId}, sequence, start, end, status, resultQuality, resultLog, processorName, processorVersion, processorLocation, parameters, parametersContentType, pStart, pTarget, pValue, pUnit, notes
        FROM TimelineStep
        WHERE experimentId = ${oldExperimentId} AND stepId = ${oldTimelineStepId};`
    );
    var newTimelineStepId = timelineStepInsertResult.lastInsertId;
    if newTimelineStepId !is int || newTimelineStepId < 0 {
        fail error("Cloning of TimelineStep with (old) id " + oldTimelineStepId.toString() + " unsuccessful [oldExperimentId: " + oldExperimentId.toString() + ", newExperimentId: " + newExperimentId.toString() + "]!");
    } else {
        io:println(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}] Cloned TimelineStep has id ${newTimelineStepId}.`); // TODO: remove
        return newTimelineStepId;
    }
}

# Clones timeline substep including associated substep data and experiment data.
#
# + newExperimentId - experiment id of the new (cloned) experiment
# + oldExperimentId - experiment id of the experiment that is being cloned
# + oldTimelineStepId - step id of (old) timeline step that is to be cloned
# + newTimelineStepId - step id of (new, target) timeline step in cloning
# + oldTimelineSubstepNr - substep nr of (old) timeline step that is to be cloned
# + oldDataIdToNewDataId - mutable mapping of old ExperimentData item ids to new experiment data ids to check if new experiment data needs to be created or not
# + return - The new (cloned) timeline step id or the encountered error
public isolated transactional function cloneTimelineSubstepComplex(int newExperimentId, int oldExperimentId, int oldTimelineStepId, map<int> oldDataIdToNewDataId, int newTimelineStepId, int oldTimelineSubstepNr) returns ()|error {
    // clone timeline substep
    var timelineSubstepInsertResult = check experimentDB->execute(
        `INSERT INTO TimelineSubstep (stepId, substepNr, substepId, href, hrefUi, cleared, parameters, parametersContentType)
        SELECT ${newTimelineStepId}, substepNr, substepId, href, hrefUi, cleared, parameters, parametersContentType
        FROM TimelineSubstep
        WHERE stepId = ${oldTimelineStepId} AND substepNr = ${oldTimelineSubstepNr};`
    );
    var rowCount = timelineSubstepInsertResult.affectedRowCount;
    if rowCount == () || rowCount < 1 {
        fail error(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}] Cloning of TimelineSubstep with substepNr ${oldTimelineSubstepNr} unsuccessful!`);
    }
    io:println(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}] Cloned substep with substepNr ${oldTimelineSubstepNr}.`); // TODO remove

    // find and clone associated substepData
    stream<record {|int id; int dataId;|}, sql:Error?> substepDataResult = experimentDB->query(`SELECT id, dataId FROM SubstepData WHERE stepId = ${oldTimelineStepId} AND substepNr=${oldTimelineSubstepNr};`);
    record {|int id; int dataId;|}[]|error|() substepDataList = from var data in substepDataResult
        select data;
    if substepDataList !is error && substepDataList !is () {
        foreach var substepData in substepDataList {
            // TODO: deep copy
            int clonedExperimentDataId = check cloneExperimentData(oldDataIdToNewDataId, substepData.dataId, newExperimentId, oldExperimentId);

            //   clone step data with id of new experiment data
            var stepDataInsertResult = check experimentDB->execute(
                `INSERT INTO SubstepData (stepId, substepNr, dataId, relationType) 
                SELECT ${newTimelineStepId}, ${oldTimelineSubstepNr}, ${clonedExperimentDataId}, relationType
                FROM StepData
                WHERE stepId = ${oldTimelineStepId} AND dataId = ${substepData.dataId};`
            );
            rowCount = stepDataInsertResult.affectedRowCount;
            if rowCount == () || rowCount < 1 {
                fail error(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}, substepNr ${oldTimelineSubstepNr}] Cloning of SubstepData with dataId ${substepData.dataId} unsuccessful.`);
            }
            io:println(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}, SubstepNr: ${oldTimelineSubstepNr}] Cloned SubstepData item with dataId ${substepData.dataId}.`); // TODO remove
        }
    }
}

# Clones timeline step including associated step data, experiment data, and substeps.
#
# + newExperimentId - experiment id of the new (cloned) experiment
# + oldExperimentId - experiment id of the experiment that is being cloned
# + oldTimelineStepId - step id of (old) timeline step that is to be cloned
# + oldDataIdToNewDataId - mutable mapping of old ExperimentData item ids to new experiment data ids to check if new experiment data needs to be created or not
# + return - The new (cloned) timeline step id or the encountered error
public isolated transactional function cloneTimelineStepComplex(int newExperimentId, int oldExperimentId, int oldTimelineStepId, map<int> oldDataIdToNewDataId) returns ()|error {
    // clone timeline step
    var newTimelineStepId = check cloneTimelineStepSimple(newExperimentId, oldExperimentId, oldTimelineStepId);

    // find and clone associated step data
    stream<record {|int id; int dataId;|}, sql:Error?> stepDataResult = experimentDB->query(`SELECT id, dataId FROM StepData WHERE stepId = ${oldTimelineStepId};`);
    record {|int id; int dataId;|}[]|error|() stepDataList = from var data in stepDataResult
        select data;
    if stepDataList !is error && stepDataList !is () {
        foreach var stepData in stepDataList {
            // check if associated experiment data was already cloned
            // TODO: deep copy
            int clonedExperimentDataId = check cloneExperimentData(oldDataIdToNewDataId, stepData.dataId, newExperimentId, oldExperimentId);
            //   clone step data with id of new experiment data
            var stepDataInsertResult = check experimentDB->execute(
                `INSERT INTO StepData (stepId, dataId, relationType) 
                SELECT ${newTimelineStepId}, ${clonedExperimentDataId}, relationType
                FROM StepData
                WHERE stepId = ${oldTimelineStepId} AND dataId = ${stepData.dataId};`
            );
            var rowCount = stepDataInsertResult.affectedRowCount;
            if rowCount == () || rowCount < 1 {
                fail error(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}] Cloning of StepData with dataId ${clonedExperimentDataId} unsuccessful!`);
            }
            io:println(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}] Cloned StepData with dataId ${stepData.dataId}.`); // TODO remove
        }
    }
    // clone all associated timeline substeps
    stream<record {|int substepNr;|}, sql:Error?> timelineSubstepResult = experimentDB->query(`SELECT substepNr FROM TimelineSubstep WHERE stepId=${oldTimelineStepId};`);
    int[]|error|() timelineSubstepNrList = from var substep in timelineSubstepResult
        select substep.substepNr;
    if timelineSubstepNrList !is error && timelineSubstepNrList !is () {
        int counter = 0;
        foreach int oldTimelineSubstepNr in timelineSubstepNrList {
            counter += 1;
            _ = check cloneTimelineSubstepComplex(newExperimentId, oldExperimentId, oldTimelineStepId, oldDataIdToNewDataId, newTimelineStepId, oldTimelineSubstepNr);
        }
        io:println(string `[experimentId ${oldExperimentId}, stepId ${oldTimelineStepId}] Cloned ${counter} TimelineSubsteps.`); // TODO remove
    }
}

# Record for exporting/importing experiment data
#
# + dataId - The database id of the data item (used for reference, changer on import)
public type ExperimentDataExport record {|
    int dataId;
    *ExperimentData; // TODO: how to map location to files in ZIP?
|};

# Record for exporting/importing step data
#
# + dataId - The database id of the data item (used for reference, changer on import)
# + relationType - the type of the relation (e.g. input/output)
public type StepData record {|
    int dataId;
    string relationType;
|};

# Record for exporting/importing substep data
#
# + substepNr - 1 based substep index   
# + dataId - The database id of the data item (used for reference, changer on import)n  
# + relationType - the type of the relation (e.g. input/output) 
public type SubstepData record {|
    string substepNr; // TODO not really necessary - maybe remove later when import is done 
    int dataId;
    string relationType;
|};

# Record for exporting/importing timeline substeps
#
# + substepNr - 1 based substep index  
# + parameters - the parameters which were input for this substep
# + parametersContentType - the content type of these parameters
# + substepDataList - list of substep data
public type TimelineSubstepExport record {|
    string substepNr;
    *TimelineSubstep;
    string parameters;
    string parametersContentType = mime:APPLICATION_FORM_URLENCODED;
    SubstepData[] substepDataList;
|};

# Record for exporting/importing timeline steps
#
# + sequence - the sequence number of the step in the experiment
# + stepDataList - list of step data  
# + timelineSubsteps - list of associated timeline substeps 
public type TimelineStepExport record {|
    int sequence; // TODO: not sure what this is used for
    *TimelineStep; // TODO: not sure if this will work due to time:Utc for start and end
    StepData[] stepDataList;
    TimelineSubstepExport[] timelineSubsteps;
|};

# Record for exporting/importing a complete experiment
#
# + experiment - info about experiment
# + timelineSteps - timeline steps including substeps and step/substep data
# + experimentDataList - list of experiment data (reference to files in zip)
public type ExperimentCompleteExport record {|
    Experiment experiment;
    TimelineStepExport[] timelineSteps;
    ExperimentData[] experimentDataList;
|};

# Prepare zip file for export of an experiment.
#
# + experimentId - experiment id of the new (cloned) experiment
# + config - export configuration
# + return - record with details about created zip files or error
public isolated transactional function exportExperiment(int experimentId, ExperimentExportConfig config) returns ExperimentExportZip|error {

    string zipFilename = "";
    string zipFileLocation = "";
    int fileLength = 0;

    Experiment experiment;
    TimelineStepExport[] timelineSteps = [];
    ExperimentData[] experimentDataList = [];

    // experiment file(s?)
    // TODO: extract all (relevant?) data of the experiment (probably as json) -> needs to contain all relevant info for reconstruction in import
    // TODO: one file or three (JSON) files?
    //      - Experiment
    experiment = check getExperimentInfo(experimentId);
    //          - name
    //          - description
    //      - list of TimelineSteps 
    //          - StepData (points to ExperimentData -> include keys)
    //          - list of TimelineSubsteps
    //              - SubstepData (points to Experimentdata -> include keys)
    //      - list of ExperimentData

    // TODO: create index file containing info about all files in zip? maybe not necessary as structure is pre-defined and implicit via file links in experiment data?

    ExperimentCompleteExport experimentComplete = {
        experiment: experiment,
        timelineSteps: timelineSteps,
        experimentDataList: experimentDataList
    };

    // data files
    // TODO: create list of all files in list of ExperimentData

    // create zip
    // TODO: add all files (experiment file(s) + data files) to ZIP

    ExperimentExportZip exportResult = {name: zipFilename, location: zipFileLocation, fileLength: fileLength};
    return exportResult;
}
