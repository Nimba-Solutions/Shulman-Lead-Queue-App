import getQueueDataApex from '@salesforce/apex/LeadQueueController.getQueueData';
import getQueueDataPagedApex from '@salesforce/apex/LeadQueueController.getQueueDataPaged';
import assignRecordApex from '@salesforce/apex/LeadQueueController.assignRecord';
import assignNextAvailableRecordApex from '@salesforce/apex/LeadQueueController.assignNextAvailableRecord';
import releaseUserAssignmentsApex from '@salesforce/apex/LeadQueueController.releaseUserAssignments';
import getUserAssignmentDataApex from '@salesforce/apex/LeadQueueController.getUserAssignmentData';
import getUserAssignedRecordIdsApex from '@salesforce/apex/LeadQueueController.getUserAssignedRecordIds';
import getAssignedRecordSummaryApex from '@salesforce/apex/LeadQueueController.getAssignedRecordSummary';
import isCacheConfiguredApex from '@salesforce/apex/LeadQueueController.isCacheConfigured';

function callApex(apexMethod, params) {
    return params ? apexMethod(params) : apexMethod();
}

export function getQueueData(params) {
    return callApex(getQueueDataApex, params);
}

export function getQueueDataPaged(params) {
    return callApex(getQueueDataPagedApex, params);
}

export function assignRecord(params) {
    return callApex(assignRecordApex, params);
}

export function assignNextAvailableRecord(params) {
    return callApex(assignNextAvailableRecordApex, params);
}

export function releaseUserAssignments(params) {
    return callApex(releaseUserAssignmentsApex, params);
}

export function getUserAssignmentData(params) {
    return callApex(getUserAssignmentDataApex, params);
}

export function getUserAssignedRecordIds(params) {
    return callApex(getUserAssignedRecordIdsApex, params);
}

export function getAssignedRecordSummary(params) {
    return callApex(getAssignedRecordSummaryApex, params);
}

export function isCacheConfigured(params) {
    return callApex(isCacheConfiguredApex, params);
}
