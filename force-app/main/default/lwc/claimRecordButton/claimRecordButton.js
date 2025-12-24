import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import assignRecord from '@salesforce/apex/LeadQueueService.assignRecord';
import releaseUserAssignments from '@salesforce/apex/LeadQueueService.releaseUserAssignments';
import getUserAssignedRecordIds from '@salesforce/apex/LeadQueueService.getUserAssignedRecordIds';
import { SharedUtils } from 'c/sharedUtils';

export default class ClaimRecordButton extends LightningElement {
    @api recordId;
    isAssigning = false;
    isReleasing = false;
    showSuccess = false;
    assignedRecordIds = [];

    // Check assignments on component load
    connectedCallback() {
        this.checkAssignments();
        // Set up periodic refresh to sync with platform cache
        this.assignmentCheckInterval = setInterval(() => {
            this.checkAssignments();
        }, 5000); // Check every 5 seconds
    }

    disconnectedCallback() {
        if (this.assignmentCheckInterval) {
            clearInterval(this.assignmentCheckInterval);
        }
    }

    async checkAssignments() {
        try {
            const assignedIds = await getUserAssignedRecordIds();
            this.assignedRecordIds = assignedIds;
        } catch (error) {
            console.error('Error getting user assignments:', error);
            this.assignedRecordIds = [];
        }
    }

    get isCurrentRecordClaimed() {
        return this.assignedRecordIds.includes(this.recordId);
    }

    get hasOtherRecordClaimed() {
        return this.assignedRecordIds.length > 0 && !this.isCurrentRecordClaimed;
    }

    get canClaimThisRecord() {
        return this.assignedRecordIds.length === 0; // No assignments at all
    }

    get claimButtonLabel() {
        return this.isAssigning ? 'Claiming...' : 'Claim Record';
    }

    get releaseButtonLabel() {
        return this.isReleasing ? 'Releasing...' : 'Release this Record';
    }

    get isClaimButtonDisabled() {
        return this.isAssigning || this.isReleasing;
    }

    get isReleaseButtonDisabled() {
        return this.isAssigning || this.isReleasing;
    }

    async handleClaimRecord() {
        if (!this.recordId) {
            this.showToast('Error', 'No record ID available', 'error');
            return;
        }

        this.isAssigning = true;
        try {
            const result = await assignRecord({ recordId: this.recordId });
            
            if (result.success) {
                this.showSuccess = true;
                this.showToast('Success', 'Record claimed successfully', 'success');
                // Refresh assignments to update button state
                await this.refreshAssignments();
                // Clear success message after 3 seconds
                setTimeout(() => {
                    this.showSuccess = false;
                }, 3000);
            } else {
                this.showToast('Warning', result.message, 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Failed to claim record: ' + SharedUtils.getErrorMessage(error), 'error');
        } finally {
            this.isAssigning = false;
        }
    }

    async handleReleaseRecord() {
        this.isReleasing = true;
        try {
            await releaseUserAssignments();
            this.showSuccess = true;
            this.showToast('Success', 'Record released successfully', 'success');
            // Refresh assignments to update button state
            await this.refreshAssignments();
            // Clear success message after 3 seconds
            setTimeout(() => {
                this.showSuccess = false;
            }, 3000);
        } catch (error) {
            this.showToast('Error', 'Failed to release record: ' + SharedUtils.getErrorMessage(error), 'error');
        } finally {
            this.isReleasing = false;
        }
    }

    async refreshAssignments() {
        // Add small delay to ensure platform cache is updated
        setTimeout(async () => {
            try {
                const assignedIds = await getUserAssignedRecordIds();
                this.assignedRecordIds = assignedIds;
            } catch (error) {
                console.error('Error refreshing assignments:', error);
            }
        }, 500); // 500ms delay for cache sync
        
        // Also do immediate refresh attempt
        await this.checkAssignments();
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

}
