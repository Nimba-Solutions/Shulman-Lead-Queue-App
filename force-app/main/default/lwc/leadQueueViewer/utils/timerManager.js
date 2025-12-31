/**
 * Timer management utilities for Lead Queue
 * Handles assignment timers, real-time updates, and timestamp processing
 */
import { SharedUtils } from 'c/sharedUtils';

export class TimerManager {
    
    constructor(component) {
        this.component = component;
    }

    /**
     * Get assignment timer for a specific record
     */
    getRecordAssignmentTimer(recordId, assignedTo, assignedTimestamp) {
        if (!assignedTo) {
            return '';
        }
        
        // Use server-provided timestamp if available
        if (assignedTimestamp) {
            try {
                // Handle both Long timestamp (from server) and ISO string formats
                let assignedTime;
                if (typeof assignedTimestamp === 'number') {
                    // Server returns Long timestamp (milliseconds since epoch)
                    assignedTime = new Date(assignedTimestamp);
                } else {
                    // ISO string format
                    assignedTime = new Date(assignedTimestamp);
                }
                
                const diffMs = this.component.currentTime - assignedTime;
                const totalSeconds = Math.floor(diffMs / 1000);
                
                // Handle negative time (future timestamps) gracefully
                if (totalSeconds < 0) {
                    return '00:00';
                }
                
                const minutes = Math.floor(totalSeconds / 60);
                const seconds = totalSeconds % 60;
                
                return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
            } catch (error) {
                // Fall through to default label without spamming console output
            }
        }
        
        // If no timestamp available but record is assigned, show this as a fallback
        // This shouldn't happen in normal operation with Platform Cache working
        return 'Assigned';
    }

    /**
     * Get utility bar timer for current user only
     */
    getUtilityBarTimer() {
        // Only show timer for records assigned to the current user
        if (this.component.hasAssignments && this.component.userAssignedRecordIds && this.component.userAssignedRecordIds.length > 0) {
            // Get the user's assigned record ID (should only be one)
            const assignedRecordId = this.component.userAssignedRecordIds[0];
            
            // Check if userAssignmentTimestamps exists and has the record
            if (!this.component.userAssignmentTimestamps) {
                return 'Time Assigned: --:--';
            }
            
            const timestamp = this.component.userAssignmentTimestamps[assignedRecordId];
            
            if (timestamp) {
                const timerValue = this.calculateTimerValue(timestamp);
                return timerValue ? `Time Assigned: ${timerValue}` : 'Time Assigned: --:--';
            }
            
            return 'Time Assigned: --:--';
        }
        
        return '';
    }

    /**
     * Helper method to calculate timer value from timestamp
     */
    calculateTimerValue(assignmentTimestamp) {
        if (!assignmentTimestamp) {
            return null;
        }
        
        try {
            // Handle both Long timestamp (from server) and ISO string formats
            let assignedTime;
            if (typeof assignmentTimestamp === 'number') {
                assignedTime = new Date(assignmentTimestamp);
            } else {
                assignedTime = new Date(assignmentTimestamp);
            }
            
            const diffMs = this.component.currentTime - assignedTime;
            const totalSeconds = Math.floor(diffMs / 1000);
            
            // Handle negative time gracefully
            if (totalSeconds < 0) {
                return '00:00';
            }
            
            const minutes = Math.floor(totalSeconds / 60);
            const seconds = totalSeconds % 60;
            
            return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
        } catch (error) {
            return null;
        }
    }

    /**
     * Refresh all table timers
     */
    refreshTableTimers() {
        // Update timer values for all assigned records (regardless of who they're assigned to)
        if (this.component.records && this.component.records.length > 0) {
            // Create a map of original records for faster lookup
            const originalRecordMap = new Map();
            this.component.originalRecords.forEach(orig => {
                originalRecordMap.set(orig.Id, orig);
            });
            
            this.component.records = this.component.records.map(record => {
                // Skip timer update if record is not assigned
                if (!record.assignedTo) {
                    return record;
                }
                
                // Preserve existing assignment timestamp if available, it contains the original assignment time
                let timestamp = record.assignmentTimestamp;
                
                // If no timestamp on record, try to get from originalRecords 
                if (!timestamp) {
                    const originalRecord = originalRecordMap.get(record.Id);
                    timestamp = originalRecord ? originalRecord.assignmentTimestamp : null;
                }
                
                return {
                    ...record,
                    assignmentTimer: this.getRecordAssignmentTimer(record.Id, record.assignedTo, timestamp)
                };
            });
        }
    }

    shouldRunTimer() {
        if (this.component.hasAssignments) {
            return true;
        }
        const records = this.component.records || [];
        return records.some(record => record && record.assignedTo);
    }

    updateTimerState() {
        if (this.shouldRunTimer()) {
            this.startTimerUpdates();
        } else {
            this.stopTimerUpdates();
        }
    }

    /**
     * Start timer interval for real-time updates
     */
    startTimerUpdates() {
        if (!this.shouldRunTimer()) {
            this.stopTimerUpdates();
            return;
        }
        if (this.component.timerInterval) {
            return;
        }

        // Initialize current time immediately
        this.component.currentTime = new Date();

        // Start live timer updates
        this.component.timerInterval = setInterval(() => {
            this.component.currentTime = new Date();
            this.refreshTableTimers();
        }, 1000); // Update every second
    }

    /**
     * Stop timer updates
     */
    stopTimerUpdates() {
        if (this.component.timerInterval) {
            clearInterval(this.component.timerInterval);
            this.component.timerInterval = null;
        }
    }

    /**
     * Get assigned record info for tooltip
     */
    getAssignedRecordInfo() {
        const assignedRecord = this.getAssignedRecordForCurrentUser();
        return assignedRecord
            ? `Currently assigned: ${assignedRecord.litify_pm__Display_Name__c || assignedRecord.Name}`
            : '';
    }

    /**
     * Get assigned record display name for utility bar
     */
    getAssignedRecordDisplayName() {
        const assignedRecord = this.getAssignedRecordForCurrentUser();
        return assignedRecord
            ? (assignedRecord.litify_pm__Display_Name__c || assignedRecord.Name)
            : 'Assigned Record';
    }

    /**
     * Get assigned record status for utility bar
     */
    getAssignedRecordStatus() {
        const assignedRecord = this.getAssignedRecordForCurrentUser();
        if (assignedRecord && assignedRecord.Status) {
            return `Status: ${assignedRecord.Status}`;
        }
        return null;
    }

    getAssignedRecordForCurrentUser() {
        if (!this.component.hasAssignments || !this.component.userAssignedRecordIds || this.component.userAssignedRecordIds.length === 0) {
            return null;
        }

        const assignedRecordId = this.component.userAssignedRecordIds[0];
        const recordMatch = (this.component.records || []).find(record => {
            const normalizedId = SharedUtils.normalizeRecordId(record.Id);
            return normalizedId === assignedRecordId;
        });

        if (recordMatch) {
            return recordMatch;
        }

        const summary = this.component.assignedRecordSummary;
        if (summary && summary.recordId === assignedRecordId) {
            return {
                Name: summary.displayName || 'Assigned Record',
                litify_pm__Display_Name__c: summary.displayName || 'Assigned Record',
                Status: summary.status || null
            };
        }

        return null;
    }
}
